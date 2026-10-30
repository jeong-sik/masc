import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from './core'
import { fetchToolBlobBytes } from './tool-blob'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'

afterEach(() => {
  clearStoredToken()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

function stalledBinaryResponse() {
  let bodyController!: ReadableStreamDefaultController<Uint8Array>
  const body = new ReadableStream<Uint8Array>({
    start(controller) { bodyController = controller },
  })
  let requestSignal: AbortSignal | null = null
  vi.stubGlobal('fetch', vi.fn((_path: string, init: RequestInit) => {
    requestSignal = init.signal ?? null
    requestSignal?.addEventListener('abort', () => {
      bodyController.error(new DOMException('Aborted', 'AbortError'))
    }, { once: true })
    return Promise.resolve(new Response(body, { status: 200 }))
  }))
  return {
    signal: () => requestSignal,
    failBody: () => bodyController.error(new DOMException('Aborted', 'AbortError')),
  }
}

describe('fetchToolBlobBytes', () => {
  it('sends the operator token and preserves binary bytes', async () => {
    setStoredToken('admin-token', { source: 'manual' })
    const buffer = new ArrayBuffer(4)
    const bytes = new Uint8Array(buffer)
    bytes.set([0, 255, 128, 42])
    const fetchMock = vi.fn().mockResolvedValue(new Response(buffer, { status: 200 }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchToolBlobBytes('a'.repeat(64))

    expect(new Uint8Array(result)).toEqual(bytes)
    expect(fetchMock).toHaveBeenCalledWith(
      `/api/v1/artifact-bytes/${'a'.repeat(64)}`,
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer admin-token' }),
      }),
    )
  })

  it('surfaces an authorization failure', async () => {
    setStoredToken('worker-token', { source: 'manual' })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status: 403 })))
    await expect(fetchToolBlobBytes('a'.repeat(64))).rejects.toMatchObject({ status: 403 })
  })

  it('keeps caller cancellation connected while the binary body is pending', async () => {
    const upstream = new AbortController()
    const stalled = stalledBinaryResponse()
    const pending = fetchToolBlobBytes('a'.repeat(64), { signal: upstream.signal })
    const rejected = expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    await new Promise<void>(resolve => setTimeout(resolve, 0))
    const signal = stalled.signal()
    if (!signal) throw new Error('fetch was not called')

    upstream.abort()
    if (!signal.aborted) stalled.failBody()
    await rejected
    expect(signal.aborted).toBe(true)
  })

  it('keeps the GET deadline active while the binary body is pending', async () => {
    vi.useFakeTimers()
    const stalled = stalledBinaryResponse()
    const pending = fetchToolBlobBytes('a'.repeat(64))
    const rejected = expect(pending).rejects.toMatchObject({ timeout: true })
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    const signal = stalled.signal()
    if (!signal) throw new Error('fetch was not called')
    if (!signal.aborted) stalled.failBody()
    await rejected
    expect(signal.aborted).toBe(true)
  })
})
