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
