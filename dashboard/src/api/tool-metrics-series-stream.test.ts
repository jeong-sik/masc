import { afterEach, describe, expect, it, vi } from 'vitest'
import { readToolSeriesStream, subscribeToolSeriesStream } from './tool-metrics-series-stream'
import type { ToolMetricsSeriesRequest } from './schemas/tool-metrics-series'
import { publishDashboardObservationChange } from '../lib/observation-refresh'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}), refreshDevTokenAfterAuthError: vi.fn(async () => false) }))
const request: ToolMetricsSeriesRequest = { sinceHours: 1, bucket: 'hour', utcOffsetMin: 0, tool: null }
const headers = { 'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '90000' }
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
const releases: Array<() => void> = []
afterEach(() => {
  for (const release of releases.splice(0)) release()
  vi.unstubAllGlobals(); vi.useRealTimers()
})

function snapshot(count: number, tool: string | null = null) {
  const stat = { call_count: count, failure_count: 0, deferred_count: 0, total_ms: count,
    p50_ms: count ? 1 : null, p95_ms: count ? 1 : null, max_ms: count ? 1 : null }
  return { generated_at: 3600, window: { since: 0, until: 3600, bucket: 'hour', bucket_seconds: 3600,
    utc_offset_min: 0 }, tool, total: stat, buckets: [{ start: 0, ...stat }], top_by_time: [] }
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
    expect(fetch.mock.calls[0]![1]).toMatchObject({ credentials: 'omit', headers: { Accept: 'text/event-stream' } })
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
    await expect(readToolSeriesStream(request, new AbortController().signal, apply))
      .rejects.toMatchObject({ name: 'ToolSeriesStreamError' })
    expect(apply).not.toHaveBeenCalled()
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
