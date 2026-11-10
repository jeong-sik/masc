import { afterEach, describe, expect, it, vi } from 'vitest'
import { readQueryObservationStream, QueryStreamProtocolError } from './query-observation-stream'
import { createQueryObservationStream } from '../lib/query-observation-stream'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}), refreshDevTokenAfterAuthError: vi.fn(async () => false) }))

const disposers: Array<() => void> = []
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
const headers = { 'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '100' }
afterEach(() => {
  for (const stop of disposers.splice(0)) stop()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('native query byte deadline', () => {
  it('counts keepalive bytes as activity, then cancels and unlocks a silently stalled body', async () => {
    vi.useFakeTimers()
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const cancel = vi.fn()
    const body = new ReadableStream<Uint8Array>({ start: controller => { writer = controller }, cancel })
    const fetch = vi.fn().mockResolvedValue(new Response(body, { headers }))
    vi.stubGlobal('fetch', fetch)
    const activity = vi.fn(), frame = vi.fn()
    const result = readQueryObservationStream('/native', new AbortController().signal,
      wire => wire, frame, activity).catch(error => error as Error)
    await flush()
    await vi.advanceTimersByTimeAsync(99)
    writer.enqueue(new TextEncoder().encode(': keepalive\n\n'))
    await flush()
    expect(activity).toHaveBeenCalledTimes(1)
    expect(frame).not.toHaveBeenCalled()
    writer.enqueue(new Uint8Array())
    await vi.advanceTimersByTimeAsync(99)
    expect(cancel).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(await result).toMatchObject({ message: expect.stringMatching(/idle timeout/) })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(cancel).toHaveBeenCalledTimes(1)
    expect(body.locked).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('opens again only after a failed body and retires the active deadline on last release', async () => {
    vi.useFakeTimers()
    const cancelled = vi.fn()
    const fetch = vi.fn().mockImplementation(async () => new Response(
      new ReadableStream<Uint8Array>({ cancel: cancelled }), { headers }))
    vi.stubGlobal('fetch', fetch)
    const subscribe = createQueryObservationStream<string, unknown, Error>({
      key: path => path, recoveryTopics: ['tool_metrics'],
      read: (path, _previous, signal, onFrame, onActivity) =>
        readQueryObservationStream(path, signal, wire => wire, onFrame, onActivity),
      merge: (_previous, frame) => frame,
      failure: cause => cause instanceof Error ? cause : new Error(String(cause)),
      terminal: cause => cause instanceof QueryStreamProtocolError,
    })
    const error = vi.fn()
    const stop = subscribe('/native', { onFrame: vi.fn(), onError: error, onReset: vi.fn() })
    disposers.push(stop)
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(99)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(error).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    stop()
    await flush()
    expect(cancelled).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([undefined, '0', '-1', '1.2', '2147483648'])('refuses unavailable or clamped deadline %s', async deadline => {
    const cancel = vi.fn()
    const body = new ReadableStream<Uint8Array>({ cancel })
    const responseHeaders: Record<string, string> = { 'content-type': 'text/event-stream' }
    if (deadline !== undefined) responseHeaders['x-masc-sse-idle-timeout-ms'] = deadline
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, { headers: responseHeaders })))
    await expect(readQueryObservationStream('/native', new AbortController().signal, wire => wire, vi.fn()))
      .rejects.toBeInstanceOf(QueryStreamProtocolError)
    expect(cancel).toHaveBeenCalledTimes(1)
  })
})
