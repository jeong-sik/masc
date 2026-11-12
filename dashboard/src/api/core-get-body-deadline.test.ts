import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  DEFAULT_GET_TIMEOUT_MS,
  get,
  getWithResponse,
  setRejectedCredentialListener,
  setStoredToken,
  type GetOptions,
} from './core'
import { resetDashboardSessionActorForTests } from '../lib/dashboard-session-actor'

type Read = (path: string, options?: GetOptions) => Promise<unknown>
const readers: Array<[string, Read]> = [
  ['get', (path, options) => get(path, options)],
  ['getWithResponse', (path, options) => getWithResponse(path, options)],
]
const releaseBodies: Array<() => void> = []

/** Actual Response body consumption, with fetch's abort wired to its source. */
function responseBody(status = 200) {
  let body!: ReadableStreamDefaultController<Uint8Array>
  let open = true
  let fetchSignal!: AbortSignal
  let aborts = 0
  const error = (reason: unknown) => {
    if (open) { open = false; body.error(reason) }
  }
  const aborted = () => { aborts += 1; error(new DOMException('Transport aborted', 'AbortError')) }
  const stream = new ReadableStream<Uint8Array>({ start(controller) { body = controller } })
  const fetch = vi.fn(async (_path: RequestInfo | URL, init?: RequestInit) => {
    fetchSignal = init?.signal as AbortSignal
    fetchSignal.addEventListener('abort', aborted, { once: true })
    return new Response(stream, { status, headers: { 'x-source': 'original-response' } })
  })
  vi.stubGlobal('fetch', fetch)
  releaseBodies.push(() => {
    fetchSignal?.removeEventListener('abort', aborted)
    error(new DOMException('Fixture released', 'AbortError'))
  })
  return {
    fetch,
    signal: () => fetchSignal,
    aborts: () => aborts,
    complete(value: string) {
      if (!open) throw new Error('response body is already closed')
      body.enqueue(new TextEncoder().encode(value)); open = false; body.close()
    },
  }
}

function settle(request: Promise<unknown>) {
  return request.then(
    value => ({ kind: 'ready' as const, value }),
    cause => ({ kind: 'failed' as const, cause }),
  )
}

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('body-deadline-token', { source: 'manual' })
  setRejectedCredentialListener(null)
})

afterEach(async () => {
  setRejectedCredentialListener(null)
  for (const release of releaseBodies.splice(0)) release()
  await vi.advanceTimersByTimeAsync(0)
  vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals()
  resetDashboardSessionActorForTests()
  window.sessionStorage.clear()
})

describe('default GET JSON body lifetime', () => {
  it.each(readers)('default %s body deadline aborts a stalled body after headers', async (_name, read) => {
    const transport = responseBody()
    const done = settle(read('/api/v1/body-deadline'))
    await vi.advanceTimersByTimeAsync(0)
    expect(transport.fetch).toHaveBeenCalledTimes(1)
    expect(transport.signal().aborted).toBe(false)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(transport.signal().aborted).toBe(true)
    expect(transport.aborts()).toBe(1)
    expect(await done).toMatchObject({ kind: 'failed', cause: {
      method: 'GET', path: '/api/v1/body-deadline', timeout: true,
    } })
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(readers)('%s keeps an explicit caller abort connected after headers', async (_name, read) => {
    const transport = responseBody()
    const caller = new AbortController()
    const added = vi.spyOn(caller.signal, 'addEventListener')
    const removed = vi.spyOn(caller.signal, 'removeEventListener')
    const done = settle(read('/api/v1/caller-body-abort', { signal: caller.signal }))
    await vi.advanceTimersByTimeAsync(0)
    expect(transport.signal().aborted).toBe(false)
    caller.abort()
    expect(transport.signal().aborted).toBe(true)
    const result = await done
    expect(result).toMatchObject({ kind: 'failed', cause: { name: 'AbortError' } })
    if (result.kind === 'failed') expect(result.cause).not.toBeInstanceOf(ApiRequestError)
    expect(removed).toHaveBeenCalledWith('abort', added.mock.calls[0]?.[1])
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(readers)('%s times out a stalled error body without credential recovery', async (_name, read) => {
    const rejected = vi.fn()
    setStoredToken('managed-body-deadline', { source: 'dev', actor: 'dashboard', role: 'admin' })
    setRejectedCredentialListener(rejected)
    const transport = responseBody(401)
    const done = settle(read('/api/v1/refused-body-deadline'))
    await vi.advanceTimersByTimeAsync(0)
    expect(rejected).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(transport.signal().aborted).toBe(true)
    expect(await done).toMatchObject({ kind: 'failed', cause: { timeout: true } })
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(rejected).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(readers)('%s ignores a 401 whose headers arrive after its deadline', async (_name, read) => {
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    let deliver!: (response: Response) => void
    let fetchSignal!: AbortSignal
    vi.stubGlobal('fetch', vi.fn((_path: RequestInfo | URL, init?: RequestInit) => {
      fetchSignal = init?.signal as AbortSignal
      return new Promise<Response>(resolve => { deliver = resolve })
    }))
    const done = settle(read('/api/v1/late-refusal-headers'))
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(fetchSignal.aborted).toBe(true)
    deliver(new Response('{"auth_error_code":"invalid_token"}', { status: 401 }))
    expect(await done).toMatchObject({ kind: 'failed', cause: { timeout: true } })
    expect(rejected).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([200, 401])('getWithResponse preserves its original header rejection for HTTP %s', async status => {
    const rejected = vi.fn()
    setRejectedCredentialListener(rejected)
    const transport = responseBody(status)
    const reason = new ApiRequestError({ method: 'GET', path: '/api/v1/scoped-read', status: 409,
      errorCode: 'observer_scope_changed' })
    const guard = vi.fn(() => { throw reason })
    const result = await settle(getWithResponse('/api/v1/scoped-read', { beforeResponseBody: guard }))
    expect(result).toEqual({ kind: 'failed', cause: reason })
    if (result.kind === 'failed') expect(result.cause).toBe(reason)
    expect(guard).toHaveBeenCalledWith(expect.objectContaining({ status }))
    expect(transport.signal().aborted).toBe(true)
    expect(transport.aborts()).toBe(1)
    await vi.advanceTimersByTimeAsync(0)
    expect(rejected).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(readers)('%s releases the deadline and caller listener after a successful body', async (name, read) => {
    const transport = responseBody()
    const caller = new AbortController()
    const added = vi.spyOn(caller.signal, 'addEventListener')
    const removed = vi.spyOn(caller.signal, 'removeEventListener')
    const done = settle(read('/api/v1/completed-body', { signal: caller.signal }))
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS - 1)
    expect(vi.getTimerCount()).toBe(1)
    transport.complete('{"ready":true}')
    expect(await done).toEqual({ kind: 'ready', value: name === 'get'
      ? { ready: true } : { data: { ready: true }, headers: expect.any(Headers) } })
    expect(removed).toHaveBeenCalledWith('abort', added.mock.calls[0]?.[1])
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    caller.abort()
    expect(transport.signal().aborted).toBe(false)
    expect(transport.aborts()).toBe(0)
  })
})
