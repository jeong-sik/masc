import { afterEach, describe, expect, it, vi } from 'vitest'
import { readDashboardLogsStream } from './dashboard-logs-stream'
import { logStreamWire } from '../test-support/logs-stream-fixture'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}) }))
afterEach(() => vi.unstubAllGlobals())

describe('native dashboard logs SSE', () => {
  it('admits one authenticated stream, decodes reset/delta frames and cancels a quiet body', async () => {
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const cancel = vi.fn()
    const stream = new ReadableStream<Uint8Array>({ start: controller => { writer = controller }, cancel })
    const fetch = vi.fn().mockResolvedValue(new Response(stream, { headers: {
      'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '90000',
    } }))
    vi.stubGlobal('fetch', fetch)
    const controller = new AbortController()
    const frames: number[][] = []
    const read = readDashboardLogsStream({ level: 'WARN', excludeCategories: ['fsm'] }, controller.signal,
      frame => { frames.push(frame.data.entries.map(entry => entry.seq)) })
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    expect(fetch.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/logs/stream?level=WARN&exclude_category=fsm')
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({ credentials: 'omit', headers: { Accept: 'text/event-stream' } })
    const bytes = new TextEncoder().encode(`data: ${JSON.stringify(logStreamWire([3, 2]))}\n\n: keepalive\n\ndata: ${JSON.stringify(logStreamWire([4], false))}\n\n`)
    writer.enqueue(bytes.slice(0, 17)); writer.enqueue(bytes.slice(17))
    await vi.waitFor(() => expect(frames).toEqual([[3, 2], [4]]))
    expect(fetch).toHaveBeenCalledTimes(1)
    controller.abort()
    await expect(read).rejects.toMatchObject({ name: 'AbortError' })
    expect(cancel).toHaveBeenCalledTimes(1)
    expect(stream.locked).toBe(false)
  })

  it('rejects malformed stream frames before they reach state', async () => {
    const body = new TextEncoder().encode(`data: ${JSON.stringify({ ...logStreamWire([]), reset: 'yes' })}\n\n`)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, { headers: {
      'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '90000',
    } })))
    const apply = vi.fn()
    await expect(readDashboardLogsStream({}, new AbortController().signal, apply))
      .rejects.toMatchObject({ _tag: 'LogsSchemaDriftError' })
    expect(apply).not.toHaveBeenCalled()
  })
})
