import { html } from 'htm/preact'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { hydrateExecutionSnapshot } from '../store'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { TelemetryUnified } from './telemetry-unified'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { __resetFleetDataCoreForTests } from './fleet-data-core'
import { getTrend, resetTrendStore } from './fleet-trend-store'

const stamp = '2026-11-10T00:00:00Z'
let generation = 0
function workspace(root: string) {
  expect(hydrateExecutionSnapshot({ projection_diagnostics: { read_completeness: 'complete', read_error: null }, execution_publication_epoch: 'telemetry-http-owner',
    execution_publication_generation: ++generation, observer_instance_id: root.slice(1),
    status: { project: 'telemetry', workspace_root: root }, agents: [], tasks: [], messages: [], keepers: [],
    execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
  })).toBe(true)
}
const pathOf = (path: string) => new URL(path, 'http://fixture').pathname
const isReplay = (path: string) => new URL(path, 'http://fixture').searchParams.get('source') === 'agent_core_event'
const rejected = (status: number) => Response.json({ error: 'access refused' }, { status })
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0) })
function answer(path: string, contextRatio = 0.2): Response {
  switch (pathOf(path)) {
    case '/api/v1/dashboard/execution': return Response.json({ generated_at: stamp,
      keepers: [{ name: 'a-only-keeper', status: 'active', keepalive_running: true, context_ratio: contextRatio,
        context_source: 'turn_record', context_metrics_unavailable: null,
        total_turns: 1, last_latency_ms: 3, last_activity_ago_s: 0, last_model_used: 'fixture', recent_tool_names: [] }],
    })
    case '/api/v1/dashboard/execution-trust': return Response.json({ generated_at: stamp, health: 'ok',
      entry_count: 0, total: 0, keepers: [] })
    case '/api/v1/dashboard/tool-quality': return Response.json({ total: 1, success: 1, failure: 0,
      success_rate: 100, by_tool: [], by_keeper: [], failure_categories: [], hourly_trend: [] })
    case '/api/v1/dashboard/telemetry/summary': return Response.json({ generated_at: stamp, sources: [], total_entries: 0 })
    case '/api/v1/dashboard/project-snapshot': return Response.json({ execution: {
      summary: { active_operations: 0, continuity_alerts: 0 }, top_queue: null, provenance: 'fixture',
    } })
    case '/api/v1/dashboard/shell': return Response.json({ status: { project: 'fixture' },
      counts: { keepers: 0, agents: 0, tasks: 0 }, auth: { enabled: false, require_token: false,
        token_present: false, token_valid: false } })
    case '/api/v1/dashboard/tools': return Response.json({ tool_inventory: { count: 0, tools: [] },
      tool_usage: { total_calls: 0, distinct_tools_called: 0, top_20: [], never_called_count: 0, registered_count: 0 } })
    case '/api/v1/dashboard/cache-stats': return Response.json({ entries: 0, fresh: 0, stale: 0, expired: 0,
      ready_fresh: 0, ready_stale: 0, computing: 0, max_entries: 500, hits_total: 0, misses_total: 0,
      hit_ratio: 0, timeout_circuit_open: 0, timeout_circuit_tracked: 0, entries_truncated_to: 50, entry_details: [] })
    case '/api/v1/dashboard/telemetry': return Response.json({ generated_at: stamp, generated_at_iso: stamp,
      dashboard_surface: '/api/v1/dashboard/telemetry', source: 'telemetry_unified', query: { n: 200 },
      count: isReplay(path) ? 0 : 1, offset: 0, entries: isReplay(path) ? [] : [{ source: 'tool_metric', ts: 1_794_268_800,
        tool_name: 'a-only-call', duration_ms: 1, success: true }] })
    default: throw new Error(`Unexpected HTTP read: ${path}`)
  }
}

beforeEach(() => {
  vi.useFakeTimers()
  localStorage.clear()
  setStoredToken('telemetry-credential', { source: 'manual' })
  workspace('/workspace-a')
  __resetFleetDataCoreForTests()
  resetTrendStore()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(() => {
  cleanup()
  clearStoredToken()
  __resetFleetDataCoreForTests()
  resetTrendStore()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('Telemetry actual HTTP failure ownership', () => {
  it('does not attach the previous workspace trend to a same-named keeper in the next workspace', async () => {
    let contextRatio = 0.2
    const fetch = vi.fn(async (path: string) => answer(path, contextRatio))
    vi.stubGlobal('fetch', fetch)
    render(html`<${FleetTelemetryPanel} />`)
    await settle()
    for (let i = 0; i < 2; i++) {
      publishDashboardObservationChange({ topic: 'telemetry' })
      await settle()
    }
    expect(getTrend('a-only-keeper', 'context_ratio')?.values).toEqual([0.2, 0.2, 0.2])
    contextRatio = 0.8
    await act(async () => { workspace('/workspace-b') })
    expect(getTrend('a-only-keeper', 'context_ratio')).toBeNull()
    await settle()
    expect(getTrend('a-only-keeper', 'context_ratio')).toBeNull()
  })

  it.each([
    ['/api/v1/dashboard/telemetry', 401], ['/api/v1/dashboard/telemetry', 403],
    ['/api/v1/dashboard/telemetry/summary', 401], ['/api/v1/dashboard/telemetry/summary', 403],
    ['/api/v1/dashboard/cache-stats', 401], ['/api/v1/dashboard/cache-stats', 403],
  ] as const)('does not retry refused %s HTTP %i when sibling reads succeeded', async (target, status) => {
    const fetch = vi.fn(async (path: string) => pathOf(path) === target && !isReplay(path) ? rejected(status) : answer(path))
    vi.stubGlobal('fetch', fetch)
    render(html`<${TelemetryUnified} />`)
    await settle()
    const targetReads = () => fetch.mock.calls.filter(([path]) => pathOf(path) === target && !isReplay(path)).length
    expect(targetReads()).toBe(1)
    publishDashboardObservationChange({ topic: 'telemetry' })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(targetReads()).toBe(1)
  })

  it('does not let an execution HTTP 500 hide a refused Fleet tool-quality sibling', async () => {
    const target = '/api/v1/dashboard/tool-quality'
    const fetch = vi.fn(async (path: string) => pathOf(path) === '/api/v1/dashboard/execution'
      ? rejected(500) : pathOf(path) === target ? rejected(403) : answer(path))
    vi.stubGlobal('fetch', fetch)
    render(html`<${FleetTelemetryPanel} />`)
    await settle()
    const targetReads = () => fetch.mock.calls.filter(([path]) => pathOf(path) === target).length
    expect(targetReads()).toBe(1)
    publishDashboardObservationChange({ topic: 'telemetry' })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(targetReads()).toBe(1)
  })
})

describe.each([
  { Component: TelemetryUnified, name: 'Telemetry', evidence: 'a-only-call', reads: 6 },
  { Component: FleetTelemetryPanel, name: 'Fleet', evidence: 'a-only-keeper', reads: 5 },
])('$name state admission', ({ Component, evidence, reads }) => {
  it('withdraws A rows immediately while B is pending and after B is refused', async () => {
    let scope = 'A'
    const pending: Array<(response: Response) => void> = []
    const fetch = vi.fn(async (path: string) => scope === 'A' ? answer(path)
      : new Promise<Response>(resolve => { pending.push(resolve) }))
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(screen.queryByText(new RegExp(evidence))).not.toBeNull()
    const panelReads = () => fetch.mock.calls.filter(([path]) => !isReplay(path)).length
    expect(panelReads()).toBe(reads)
    scope = 'B'
    await act(async () => { workspace('/workspace-b') })
    expect(screen.queryByText(new RegExp(evidence))).toBeNull()
    await settle()
    expect(pending).toHaveLength(reads)
    await act(async () => { for (const resolve of pending) resolve(rejected(403)) })
    await settle()
    expect(screen.queryByText(new RegExp(evidence))).toBeNull()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(panelReads()).toBe(reads * 2)
  })
})
