import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ fetchControlPlane: vi.fn() }))
vi.mock('./api/core', () => ({
  authHeaders: () => ({ Authorization: 'Bearer test' }),
  fetchControlPlane: mocks.fetchControlPlane,
  subscribeStoredTokenChanges: () => () => {},
}))
vi.mock('./api/dev-token', () => ({ ensureDevToken: vi.fn() }))

import { startKeeperWaitingObserver } from './keeper-waiting-observer-client'

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
  mocks.fetchControlPlane.mockReset()
})

describe('waiting observer stream and lifecycle', () => {
  it('keeps a healthy connection, then marks an idle stream unavailable and reconnects', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    const sources: Array<ReadableStreamDefaultController<Uint8Array>> = []
    const cancel = vi.fn()
    mocks.fetchControlPlane.mockImplementation((_path: string, options: RequestInit) => {
      let closed = false
      let source!: ReadableStreamDefaultController<Uint8Array>
      const body = new ReadableStream<Uint8Array>({
        start(controller) { source = controller; sources.push(controller) },
        cancel() { closed = true; cancel() },
      })
      options.signal?.addEventListener('abort', () => {
        if (!closed) { closed = true; source.error(new DOMException('aborted', 'AbortError')) }
      }, { once: true })
      return Promise.resolve(new Response(body, { headers: {
        'content-type': 'text/event-stream',
        'x-masc-sse-instance-id': 'process.epoch',
        'x-masc-sse-replay': 'fresh',
        'x-masc-sse-idle-timeout-ms': '1000',
      } }))
    })
    const callbacks = { ready: vi.fn(), change: vi.fn(), unavailable: vi.fn() }
    const control = startKeeperWaitingObserver(callbacks)
    try {
      await vi.advanceTimersByTimeAsync(0)
      expect(callbacks.ready).toHaveBeenCalledWith('process.epoch')
      await vi.advanceTimersByTimeAsync(900)
      sources[0]!.enqueue(new TextEncoder().encode(': ping\n\n'))
      await vi.advanceTimersByTimeAsync(900)
      expect(mocks.fetchControlPlane).toHaveBeenCalledOnce()
      expect(callbacks.unavailable).not.toHaveBeenCalled()
      await vi.advanceTimersByTimeAsync(100)
      expect(cancel).toHaveBeenCalledOnce()
      expect(callbacks.unavailable).toHaveBeenCalledWith('disconnected')
      await vi.advanceTimersByTimeAsync(999)
      expect(mocks.fetchControlPlane).toHaveBeenCalledOnce()
      await vi.advanceTimersByTimeAsync(1)
      expect(mocks.fetchControlPlane).toHaveBeenCalledTimes(2)
      expect(callbacks.ready).toHaveBeenCalledTimes(2)
    } finally {
      control.stop()
    }
  })
})
