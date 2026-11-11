import { html } from 'htm/preact'
import { Component, type ComponentChildren } from 'preact'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { decodeModelMetricsFrame, subscribeModelMetricsStream } from '../api/model-metrics-stream'
import { QueryStreamProtocolError } from '../api/query-observation-stream'
import { clearStoredToken, setStoredToken } from '../api/core'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { CostDashboard } from './cost-dashboard'
import { RuntimeMonitor } from './runtime-monitor'
import { OverviewRuntimeStats } from './overview/runtime-stats'
import { viewMode, windowMinutes } from './cost/cost-store'
import { route } from '../router'

vi.mock('../api/dev-token', () => ({ ensureDevToken: vi.fn(async () => {}), refreshDevTokenAfterAuthError: vi.fn(async () => false) }))
vi.mock('../api/dashboard', async original => ({ ...await original<typeof import('../api/dashboard')>(),
  fetchRuntimeProviders: vi.fn(async () => ({ providers: [] })),
  fetchDashboardRuntimeProbe: vi.fn(async () => ({ probe: { providers: [], summary: {} } })),
}))
vi.mock('../lib/runtime-catalog-resource', () => ({
  runtimeCatalogState: { value: { status: 'idle' } }, loadRuntimeCatalog: vi.fn(), reloadRuntimeCatalog: vi.fn(async () => {}),
}))

const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve() }
type Connection = { path: string; signal: AbortSignal; source: ReadableStreamDefaultController<Uint8Array> }
let connections: Connection[]
let renderErrors: Error[]
class Boundary extends Component<{ children?: ComponentChildren }, { failed: boolean }> {
  state = { failed: false }
  componentDidCatch(error: Error) { renderErrors.push(error); this.setState({ failed: true }) }
  render() { return this.state.failed ? null : this.props.children }
}
function frame(window: number, bucket: number, model = `native-${window}-${bucket}`) {
  return { window_minutes: window, bucket_minutes: bucket,
    cost_ledger_read: { state: 'available', malformed_rows: 0, schema_violation_rows: 0, identity_conflict_rows: 0 },
    total_entries: 1, total_error_entries: 0, latency_buckets: [],
    models: [{ model_id: model, success_count: 1, error_count: 0,
      total_input_tokens: null, total_output_tokens: 0, total_cost_usd: null }] }
}
function send(connection: Connection, wire: unknown) {
  connection.source.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(wire)}\n\n`))
}
function stream(path: string, signal: AbortSignal, initial = true): Response {
  const url = new URL(path, window.location.origin)
  let connection!: Connection
  const body = new ReadableStream<Uint8Array>({ start(source) { connection = { path, signal, source }; connections.push(connection) } })
  if (initial) send(connection, frame(Number(url.searchParams.get('window')), Number(url.searchParams.get('bucket_min'))))
  return new Response(body, { headers: { 'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '90000', 'x-masc-sse-instance-id': executionWorkspaceAuthority.peek()!.observerInstanceId! } })
}
beforeEach(() => {
  vi.useFakeTimers(); connections = []; renderErrors = []
  confirmRuntimeTestWorkspace(); viewMode.value = 'model'; windowMinutes.value = 60
  route.value = { tab: 'monitoring', params: { section: 'runtime', view: 'cost' }, postId: null }
})
afterEach(() => { cleanup(); clearStoredToken(); vi.unstubAllGlobals(); vi.useRealTimers() })

it('moves all three mounted panels to native queries, with no healthy status reads', async () => {
  const fetch = vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!))
  vi.stubGlobal('fetch', fetch)
  const overview = render(html`<${OverviewRuntimeStats} />`)
  const runtime = render(html`<${Boundary}><${RuntimeMonitor} /><//>`)
  const cost = render(html`<${Boundary}><${CostDashboard} /><//>`)
  const text = () => overview.container.textContent! + runtime.container.textContent! + cost.container.textContent!
  await act(async () => { await flush(); await vi.advanceTimersByTimeAsync(0) })
  await act(async () => { vi.advanceTimersToNextFrame(); await flush() })
  expect(fetch.mock.calls.map(([path]) => path).sort()).toEqual([
    '/api/v1/models/metrics/stream?window=30&bucket_min=5',
    '/api/v1/models/metrics/stream?window=60&bucket_min=0',
    '/api/v1/models/metrics/stream?window=60&bucket_min=5',
  ])
  for (const [, init] of fetch.mock.calls) {
    expect(new Headers(init.headers).get('x-masc-sse-instance-id'))
      .toBe(executionWorkspaceAuthority.peek()!.observerInstanceId)
  }
  await vi.waitFor(() => {
    expect(renderErrors).toEqual([])
    expect(text()).toContain('native-60-0')
    expect(text()).toContain('native-30-5')
    expect(text()).toContain('native-60-5')
  })
  for (let i = 0; i < 4; i++) {
    for (const connection of connections.filter(c => !c.signal.aborted)) connection.source.enqueue(new TextEncoder().encode(': keepalive\n\n'))
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
  }
  expect(fetch).toHaveBeenCalledTimes(3)
  fireEvent.click(overview.getByRole('button', { name: '통계 새로 읽기' }))
  await act(flush)
  expect(fetch).toHaveBeenCalledTimes(4)
  expect(fetch.mock.calls[3]![0]).toBe('/api/v1/models/metrics/stream?window=60&bucket_min=0')
  fireEvent.change(runtime.getByRole('combobox', { name: '시간 윈도우 선택' }), { target: { value: '60' } })
  await act(flush)
  expect(fetch).toHaveBeenCalledTimes(4)
  await vi.waitFor(() => expect(connections.find(c => c.path.includes('window=30'))?.signal.aborted).toBe(true))
  const shared = connections.find(c => c.path.endsWith('window=60&bucket_min=5'))!
  await act(async () => { send(shared, frame(60, 5, 'committed-shared')); await flush() })
  await vi.waitFor(() => {
    expect(runtime.container.textContent).toContain('committed-shared')
    expect(cost.container.textContent).toContain('committed-shared')
  })
  fireEvent.click(runtime.getByRole('button', { name: 'runtime snapshot 새로고침' }))
  await act(flush)
  expect(fetch).toHaveBeenCalledTimes(5)
  expect(fetch.mock.calls[4]![0]).toBe('/api/v1/models/metrics/stream?window=60&bucket_min=5')
  expect(shared.signal.aborted).toBe(true)
  overview.unmount(); runtime.unmount(); cost.unmount()
  await act(flush)
  expect(connections.every(c => c.signal.aborted)).toBe(true)
  expect(vi.getTimerCount()).toBe(0)
})

it('withdraws prior authority metrics before new frames, including an unmounted token gap', async () => {
  let initial = true
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, initial)))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(flush)
  expect(view.container.textContent).toContain('native-60-0')
  initial = false
  invalidateExecutionSnapshotGeneration('models-new-workspace', 0)
  await act(async () => {
    hydrateExecutionSnapshot({ observer_instance_id: 'models-new-instance', execution_publication_epoch: 'models-new-workspace', execution_publication_generation: 1,
      status: { project: 'new', workspace_root: '/new' } } as Parameters<typeof hydrateExecutionSnapshot>[0])
    await flush()
  })
  expect(view.container.textContent).not.toContain('native-60-0')
  expect(connections[0]!.signal.aborted).toBe(true)
  const current = [...connections].reverse().find(connection => !connection.signal.aborted)!
  await act(async () => { send(current, frame(60, 0, 'workspace-B-metric')); await flush() })
  await vi.waitFor(() => expect(view.container.textContent).toContain('workspace-B-metric'))
  view.unmount()
  setStoredToken('gap-authority', { source: 'manual' })
  invalidateExecutionSnapshotGeneration('models-unmounted-workspace', 0)
  hydrateExecutionSnapshot({ observer_instance_id: 'models-unmounted-instance', execution_publication_epoch: 'models-unmounted-workspace', execution_publication_generation: 1,
    status: { project: 'unmounted', workspace_root: '/unmounted' } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  const next = render(html`<${OverviewRuntimeStats} />`)
  await act(flush)
  expect(next.container.textContent).not.toContain('native-60-0')
  expect(next.container.textContent).not.toContain('workspace-B-metric')
})

it('retains actual reader failure debt and never retries successful pending/mismatched projections', async () => {
  const fetch = vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, false))
  vi.stubGlobal('fetch', fetch)
  const received = vi.fn(), error = vi.fn()
  const stop = subscribeModelMetricsStream({ windowMinutes: 60, bucketMinutes: 0 }, { onReset: vi.fn(), onFrame: received, onError: error })
  await flush()
  send(connections[0]!, { error: 'temporary decision store unavailable' }); await flush()
  expect(error).toHaveBeenCalledOnce()
  await vi.advanceTimersByTimeAsync(1_000)
  expect(fetch).toHaveBeenCalledTimes(2)
  send(connections[1]!, { error: 'decision store is still unavailable' }); await flush()
  await vi.advanceTimersByTimeAsync(1_999)
  expect(fetch).toHaveBeenCalledTimes(2)
  await vi.advanceTimersByTimeAsync(1)
  expect(fetch).toHaveBeenCalledTimes(3)
  send(connections[2]!, frame(60, 0)); await flush()
  expect(received).toHaveBeenCalledOnce()
  stop(); stop.refresh()
  await vi.advanceTimersByTimeAsync(300_000)
  expect(fetch).toHaveBeenCalledTimes(3)
  expect(() => decodeModelMetricsFrame({ windowMinutes: 60, bucketMinutes: 0 }, { ...frame(60, 0), cost_ledger_read: { state: 'pending' } }))
    .toThrow(QueryStreamProtocolError)
  expect(() => decodeModelMetricsFrame({ windowMinutes: 60, bucketMinutes: 0 }, frame(30, 0))).toThrow(QueryStreamProtocolError)
})

it('keeps the subscribed query immutable and preserves unreported versus zero usage', async () => {
  const fetch = vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!))
  vi.stubGlobal('fetch', fetch)
  const query = { windowMinutes: 60, bucketMinutes: 0 }
  const received = vi.fn()
  const stop = subscribeModelMetricsStream(query, { onReset: vi.fn(), onFrame: received, onError: vi.fn() })
  query.windowMinutes = 30
  await flush()
  expect(fetch.mock.calls[0]![0]).toBe('/api/v1/models/metrics/stream?window=60&bucket_min=0')
  expect(received).toHaveBeenCalledOnce()
  expect(received.mock.calls[0]![0].models[0]).toMatchObject({
    total_input_tokens: null, total_output_tokens: 0, total_cost_usd: null,
  })
  stop()
})

it('retains partial metric rows and their cost read failure through EOF and retry until a complete frame', async () => {
  const fetch = vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, false))
  vi.stubGlobal('fetch', fetch)
  const overview = render(html`<${OverviewRuntimeStats} />`)
  const runtime = render(html`<${Boundary}><${RuntimeMonitor} /><//>`)
  const cost = render(html`<${Boundary}><${CostDashboard} /><//>`)
  const views = [overview, runtime, cost]
  await act(async () => { await flush(); vi.advanceTimersToNextFrame(); await flush() })
  const originalConnections = [...connections]
  expect(originalConnections).toHaveLength(3)
  await act(async () => {
    for (const connection of originalConnections) {
      const query = new URL(connection.path, window.location.origin).searchParams
      send(connection, { ...frame(Number(query.get('window')), Number(query.get('bucket_min')), 'partial-decision-row'),
        cost_ledger_read: { state: 'unavailable', detail: 'original cost ledger IO failure' } })
      connection.source.close()
    }
    await flush()
  })
  await vi.waitFor(() => {
    expect(renderErrors).toEqual([])
    for (const view of views) {
      expect(view.container.textContent).toContain('partial-decision-row')
      expect(view.container.querySelector('[role="alert"]')).not.toBeNull()
    }
    expect(overview.container.textContent).toContain('original cost ledger IO failure')
  })
  await act(async () => { await vi.advanceTimersByTimeAsync(1_000); await flush() })
  expect(fetch).toHaveBeenCalledTimes(6)
  for (const view of views) expect(view.container.textContent).toContain('partial-decision-row')
  await act(async () => {
    for (const connection of connections.slice(originalConnections.length)) {
      const query = new URL(connection.path, window.location.origin).searchParams
      send(connection, frame(Number(query.get('window')), Number(query.get('bucket_min')), 'complete-after-cost-recovery'))
    }
    await flush()
  })
  await vi.waitFor(() => {
    for (const view of views) {
      expect(view.container.textContent).toContain('complete-after-cost-recovery')
      expect(view.container.textContent).not.toContain('partial-decision-row')
      expect(view.container.textContent).not.toContain('original cost ledger IO failure')
      expect(view.container.querySelector('[role="alert"]')).toBeNull()
    }
  })
})

it('withdraws retained partial metrics when the query or workspace changes before another frame', async () => {
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, false)))
  const view = render(html`<${Boundary}><${RuntimeMonitor} /><//>`)
  await act(flush)
  const first = connections[0]!
  await act(async () => {
    send(first, { ...frame(30, 5, 'query-A-partial-row'),
      cost_ledger_read: { state: 'unavailable', detail: 'query-A-cost-failure' } })
    first.source.close()
    await flush()
  })
  await vi.waitFor(() => expect(view.container.textContent).toContain('query-A-partial-row'))
  fireEvent.change(view.getByRole('combobox', { name: '시간 윈도우 선택' }), { target: { value: '60' } })
  await act(flush)
  expect(view.container.textContent).not.toContain('query-A-partial-row')
  expect(view.container.textContent).not.toContain('query-A-cost-failure')
  expect(first.signal.aborted).toBe(true)
  const next = connections.at(-1)!
  await act(async () => {
    send(next, { ...frame(60, 5, 'workspace-A-partial-row'),
      cost_ledger_read: { state: 'unavailable', detail: 'workspace-A-cost-failure' } })
    next.source.close()
    await flush()
  })
  await vi.waitFor(() => expect(view.container.textContent).toContain('workspace-A-partial-row'))
  invalidateExecutionSnapshotGeneration('partial-workspace-B', 0)
  await act(async () => {
    hydrateExecutionSnapshot({ projection_diagnostics: { read_completeness: 'complete', read_error: null },
      observer_instance_id: 'partial-workspace-B-instance',
      execution_publication_epoch: 'partial-workspace-B', execution_publication_generation: 1,
      status: { project: 'B', workspace_root: '/partial-B' } } as Parameters<typeof hydrateExecutionSnapshot>[0])
    await flush()
  })
  expect(view.container.textContent).not.toContain('workspace-A-partial-row')
  expect(view.container.textContent).not.toContain('workspace-A-cost-failure')
  expect(next.signal.aborted).toBe(true)
  await act(async () => { connections.at(-1)!.source.error(new Error('workspace-B-body-failed')); await flush() })
  expect(view.container.textContent).not.toContain('workspace-A-partial-row')
  expect(renderErrors).toEqual([])
})

it('keeps partial cost IO failure debt across bodies and resets backoff only after a complete read', async () => {
  const fetch = vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, false))
  vi.stubGlobal('fetch', fetch)
  const received = vi.fn(), error = vi.fn()
  const stop = subscribeModelMetricsStream({ windowMinutes: 60, bucketMinutes: 0 }, {
    onReset: vi.fn(), onFrame: received, onError: error,
  })
  await flush()
  for (const [index, delay] of [1_000, 2_000, 4_000].entries()) {
    const connection = connections[index]!
    send(connection, { ...frame(60, 0), cost_ledger_read: { state: 'unavailable', detail: 'temporary IO failure' } })
    connection.source.close()
    await flush()
    expect(received).toHaveBeenCalledTimes(index + 1)
    expect(received.mock.lastCall![0].cost_ledger_read).toEqual({ state: 'unavailable', detail: 'temporary IO failure' })
    expect(error).toHaveBeenCalledTimes(index + 1)
    await vi.advanceTimersByTimeAsync(delay - 1)
    expect(fetch).toHaveBeenCalledTimes(index + 1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(index + 2)
  }
  send(connections[3]!, frame(60, 0, 'complete-after-recovery'))
  connections[3]!.source.close()
  await flush()
  expect(received).toHaveBeenCalledTimes(4)
  await vi.advanceTimersByTimeAsync(999)
  expect(fetch).toHaveBeenCalledTimes(4)
  await vi.advanceTimersByTimeAsync(1)
  expect(fetch).toHaveBeenCalledTimes(5)
  stop()
  await flush()
  expect(vi.getTimerCount()).toBe(0)
})

it('retains partial rows beside unavailable state in every panel after the failed body closes', async () => {
  vi.stubGlobal('fetch', vi.fn(async (path: string, init: RequestInit) => stream(path, init.signal!, false)))
  const overview = render(html`<${OverviewRuntimeStats} />`)
  const runtime = render(html`<${Boundary}><${RuntimeMonitor} /><//>`)
  const cost = render(html`<${Boundary}><${CostDashboard} /><//>`)
  await act(async () => { await flush(); vi.advanceTimersToNextFrame(); await flush() })
  await act(async () => {
    for (const connection of connections) {
      const query = new URL(connection.path, window.location.origin).searchParams
      send(connection, { ...frame(Number(query.get('window')), Number(query.get('bucket_min')), 'partial-retained-row'),
        cost_ledger_read: { state: 'unavailable', detail: 'temporary cost IO failure' } })
      connection.source.close()
    }
    await flush()
  })
  await vi.waitFor(() => {
    expect(renderErrors).toEqual([])
    for (const view of [overview, runtime, cost]) {
      expect(view.container.textContent).toContain('partial-retained-row')
      expect(view.container.querySelector('[role="alert"]')).not.toBeNull()
    }
  })
})

it.each([401, 403])('keeps an actual %s refusal stopped across manual query refresh', async status => {
  setStoredToken(`refused-${status}`, { source: 'manual' })
  const fetch = vi.fn(async () => new Response(JSON.stringify({ error: 'refused', auth_error_code: 'invalid_token' }), {
    status, headers: { 'content-type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetch)
  const error = vi.fn()
  const stop = subscribeModelMetricsStream({ windowMinutes: 60, bucketMinutes: 0 }, { onReset: vi.fn(), onFrame: vi.fn(), onError: error })
  await flush()
  expect(error).toHaveBeenCalledOnce()
  stop.refresh()
  await vi.advanceTimersByTimeAsync(300_000)
  expect(fetch).toHaveBeenCalledTimes(1)
  stop()
})
