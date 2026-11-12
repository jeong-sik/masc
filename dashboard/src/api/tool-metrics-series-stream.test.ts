import { confirmRuntimeTestWorkspace, RUNTIME_TEST_OBSERVER_INSTANCE } from '../lib/runtime-workspace.test-fixture'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { readToolSeriesStream, subscribeToolSeriesStream } from './tool-metrics-series-stream'
import type { ToolMetricsSeriesRequest } from './schemas/tool-metrics-series'
import { publishDashboardObservationChange } from '../lib/observation-refresh'
import { TRANSPORT_RETRY_BASE_MS } from '../config/constants'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}), refreshDevTokenAfterAuthError: vi.fn(async () => false) }))
const request: ToolMetricsSeriesRequest = { sinceHours: 1, bucket: 'hour', utcOffsetMin: 0, tool: null }
const headers = { 'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '90000', 'x-masc-sse-instance-id': RUNTIME_TEST_OBSERVER_INSTANCE }
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
const releases: Array<() => void> = []
beforeEach(confirmRuntimeTestWorkspace)
afterEach(() => {
  for (const release of releases.splice(0)) release()
  vi.unstubAllGlobals(); vi.useRealTimers()
})

function snapshot(count: number, tool: string | null = null) {
  const stat = { call_count: count, failure_count: 0, deferred_count: 0, total_ms: count,
    p50_ms: count ? 1 : null, p95_ms: count ? 1 : null, max_ms: count ? 1 : null,
    long_count: 0, long_total_ms: 0 }
  return { generated_at: 3600, window: { since: 0, until: 3600, bucket: 'hour', bucket_seconds: 3600,
    utc_offset_min: 0 }, tool, long_call_ms: 60_000, total: stat, buckets: [{ start: 0, ...stat }], top_by_time: [] }
}

describe('native series query', () => {
  it('shares one authenticated query and takes source-expiry snapshots without REST/status GET', async () => {
    vi.useFakeTimers()
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const cancel = vi.fn()
    const body = new ReadableStream<Uint8Array>({ start: controller => { writer = controller }, cancel })
    const fetch = vi.fn().mockResolvedValue(new Response(body, { headers }))
    vi.stubGlobal('fetch', fetch)
    const first = vi.fn(), second = vi.fn()
    const a = subscribeToolSeriesStream(request, { onFrame: first, onError: vi.fn(), onReset: vi.fn() })
    releases.push(a)
    await flush()
    expect(fetch.mock.calls[0]![0]).toBe('/api/v1/tool-metrics/series/stream?since_hours=1&bucket=hour&utc_offset_min=0')
    expect(fetch.mock.calls[0]![1]).toMatchObject({ credentials: 'omit', headers: {
      Accept: 'text/event-stream', 'x-masc-sse-instance-id': RUNTIME_TEST_OBSERVER_INSTANCE,
    } })
    const emit = (count: number) => writer.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(snapshot(count))}\n\n`))
    emit(2)
    await flush()
    const b = subscribeToolSeriesStream(request, { onFrame: second, onError: vi.fn(), onReset: vi.fn() })
    releases.push(b)
    expect(second.mock.calls[0]![0].total.call_count).toBe(2)
    publishDashboardObservationChange({ topic: 'tool_metrics' })
    await vi.advanceTimersByTimeAsync(60_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    emit(1)
    await flush()
    expect(first.mock.lastCall![0].total.call_count).toBe(1)
    expect(second.mock.lastCall![0].total.call_count).toBe(1)
    a()
    expect(cancel).not.toHaveBeenCalled()
    b()
    await flush()
    expect(cancel).toHaveBeenCalledTimes(1)
    expect(body.locked).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('refuses a frame answering a different query before it reaches state', async () => {
    const body = new TextEncoder().encode(`data: ${JSON.stringify(snapshot(1, 'other-tool'))}\n\n`)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, { headers })))
    const apply = vi.fn()
    await expect(readToolSeriesStream(request, RUNTIME_TEST_OBSERVER_INSTANCE, new AbortController().signal, apply))
      .rejects.toMatchObject({ name: 'ToolSeriesStreamError' })
    expect(apply).not.toHaveBeenCalled()
  })

  it('recovers a server read-error frame without a later event and keeps the recovered stream quiet', async () => {
    vi.useFakeTimers()
    let recovered!: ReadableStreamDefaultController<Uint8Array>
    const fetch = vi.fn().mockResolvedValueOnce(new Response(
      `data: ${JSON.stringify({ error: 'original SQLite busy' })}\n\n`, { headers },
    )).mockImplementation(() => Promise.resolve(new Response(new ReadableStream<Uint8Array>({
      start: writer => {
        recovered = writer
        writer.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(snapshot(3))}\n\n`))
      },
    }), { headers })))
    vi.stubGlobal('fetch', fetch)
    const onFrame = vi.fn(), onError = vi.fn()
    releases.push(subscribeToolSeriesStream(request, { onFrame, onError, onReset: vi.fn() }))
    await flush(); await flush()
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.lastCall![0].message).toBe('original SQLite busy')
    await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_BASE_MS)
    await flush(); await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(onFrame.mock.lastCall![0].total.call_count).toBe(3)
    for (let i = 0; i < 3; i++) {
      recovered.enqueue(new TextEncoder().encode(': keepalive\n\n'))
      await vi.advanceTimersByTimeAsync(30_000)
    }
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(onError).toHaveBeenCalledTimes(1)
  })

  it.each([401, 403])('keeps actual HTTP %i terminal while ordinary source events arrive', async status => {
    vi.useFakeTimers()
    const fetch = vi.fn().mockImplementation(() => Promise.resolve(Response.json({ error: 'refused' }, { status })))
    vi.stubGlobal('fetch', fetch)
    const onError = vi.fn(), onFrame = vi.fn()
    releases.push(subscribeToolSeriesStream(request, { onFrame, onError, onReset: vi.fn() }))
    await flush(); await flush()
    expect(onError).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'tool_metrics' })
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(180_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(onFrame).not.toHaveBeenCalled()
  })

  it('keeps a malformed series payload terminal', async () => {
    vi.useFakeTimers()
    const fetch = vi.fn().mockImplementation(() => Promise.resolve(new Response(
      `data: ${JSON.stringify({ error: 503 })}\n\n`, { headers },
    )))
    vi.stubGlobal('fetch', fetch)
    const onError = vi.fn(), onFrame = vi.fn()
    releases.push(subscribeToolSeriesStream(request, { onFrame, onError, onReset: vi.fn() }))
    await flush(); await flush()
    await vi.advanceTimersByTimeAsync(180_000)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onFrame).not.toHaveBeenCalled()
  })

  it('retires the previous query fetch when the picked tool changes', async () => {
    const signals: AbortSignal[] = []
    const fetch = vi.fn().mockImplementation(async (_path, options) => {
      signals.push(options.signal)
      return new Response(new ReadableStream<Uint8Array>(), { headers })
    })
    vi.stubGlobal('fetch', fetch)
    const reader = { onFrame: vi.fn(), onError: vi.fn(), onReset: vi.fn() }
    const stop = subscribeToolSeriesStream(request, reader)
    releases.push(stop)
    await flush()
    stop()
    releases.push(subscribeToolSeriesStream({ ...request, tool: 'tool_execute' }, reader))
    await flush()
    expect(signals[0]!.aborted).toBe(true)
    expect(signals[1]!.aborted).toBe(false)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(fetch.mock.calls[1]![0]).toContain('tool=tool_execute')
  })
})
