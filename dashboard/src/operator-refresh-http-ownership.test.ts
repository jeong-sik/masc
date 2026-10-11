import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from './api/core'
import { refreshOperatorSnapshot, refreshOperatorWorkspaceDigest } from './operator-actions'
vi.mock('./sse-store', () => ({ registerOperatorRefresh: vi.fn() }))
const fetchMock = vi.fn()
beforeEach(() => { clearStoredToken(); fetchMock.mockReset(); vi.stubGlobal('fetch', fetchMock) })
afterEach(() => { clearStoredToken(); vi.unstubAllGlobals() })

it.each(['snapshot', 'digest'] as const)('aborts %s HTTP acquisition on credential replacement', async (kind) => {
  setStoredToken('synthetic-http-owner-a')
  let signal!: AbortSignal
  let finish!: (response: Response) => void
  fetchMock.mockImplementation((_path: string, init: RequestInit) => new Promise<Response>((resolve, reject) => {
    signal = init.signal!
    finish = resolve
    signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
  }))
  const pending = kind === 'snapshot' ? refreshOperatorSnapshot({ force: true }) : refreshOperatorWorkspaceDigest({ force: true })
  await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
  setStoredToken('synthetic-http-owner-b')
  try {
    expect(signal.aborted).toBe(true)
  } finally {
    if (!signal.aborted) finish(new Response('{}'))
    await pending
  }
})

it.each(['snapshot', 'digest'] as const)('keeps %s HTTP cancellation connected during response body read', async (kind) => {
  setStoredToken('synthetic-body-owner-a')
  let signal!: AbortSignal
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value } })
  const response = new Response(body)
  let reading = false
  const originalText = response.text.bind(response)
  const read = vi.spyOn(response, 'text').mockImplementation(() => { reading = true; return originalText() })
  fetchMock.mockImplementation((_path: string, init: RequestInit) => {
    signal = init.signal!
    // Controlled transport models native fetch aborting its open response.
    signal.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')), { once: true })
    return Promise.resolve(response)
  })
  const pending = kind === 'snapshot' ? refreshOperatorSnapshot({ force: true }) : refreshOperatorWorkspaceDigest({ force: true })
  await vi.waitFor(() => expect(reading).toBe(true))
  setStoredToken('synthetic-body-owner-b')
  try {
    expect(signal.aborted).toBe(true)
  } finally {
    if (!signal.aborted) {
      controller.enqueue(new TextEncoder().encode('{}'))
      controller.close()
    }
    await pending
    read.mockRestore()
  }
})

it.each([200, 500])('preserves a typed GET timeout while reading the %s response body', async (status) => {
  const { get, ApiRequestError } = await import('./api/core')
  vi.useFakeTimers()
  let signal!: AbortSignal
  let controller!: ReadableStreamDefaultController<Uint8Array<ArrayBuffer>>
  let started!: () => void
  const reading = new Promise<void>(resolve => { started = resolve })
  const body = new ReadableStream<Uint8Array<ArrayBuffer>>({ start(value) { controller = value } })
  const response = new Response(body, { status })
  const originalText = response.text.bind(response)
  const read = vi.spyOn(response, 'text').mockImplementation(() => { started(); return originalText() })
  fetchMock.mockImplementation((_path: string, init: RequestInit) => {
    signal = init.signal!
    signal.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')), { once: true })
    return Promise.resolve(response)
  })
  const pending = get('/api/v1/operator', { timeoutMs: 10 }).catch(error => error)
  try {
    await reading
    await vi.advanceTimersByTimeAsync(10)
    expect(signal.aborted).toBe(true)
    const error = await pending
    expect(error).toBeInstanceOf(ApiRequestError)
    if (!(error instanceof ApiRequestError)) throw error
    expect(error.timeout).toBe(true)
    expect(error.method).toBe('GET')
    expect(error.path).toBe('/api/v1/operator')
  } finally {
    if (!signal.aborted) { controller.enqueue(new TextEncoder().encode('{}')); controller.close() }
    await pending
    read.mockRestore()
    vi.useRealTimers()
  }
})
