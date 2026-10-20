import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  authHeaders,
  fetchControlPlane,
  get,
  getStoredToken,
  getStoredTokenMeta,
  jsonHeaders,
  setStoredToken,
} from './core'
import { installRejectedCredentialRecovery, resetDevTokenBootstrap } from './dev-token'

/* #44189: a tab holding a pasted token the server had stopped accepting kept
   polling `/api/v1/dashboard/runtime-probe` and `/api/v1/board/reactions` with
   it, and the server answered 401 twice a minute for the life of the tab. */

const DEV_TOKEN_PATH = '/api/v1/dashboard/dev-token'

function refusal(code: string): Response {
  return new Response(JSON.stringify({ error: 'refused', auth_error_code: code }), {
    status: 401,
    headers: { 'Content-Type': 'application/json' },
  })
}

function sentAuthorization(init: RequestInit | undefined): string | null {
  return new Headers(init?.headers).get('Authorization')
}

async function settle(): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, 10))
}

/* A "keeps the token" case alone would also pass if recovery never ran. Each
   one ends by showing recovery is live: a later expired refusal of the same
   stored token drops it. */
async function expectRecoveryStillDropsExpired(): Promise<void> {
  vi.stubGlobal('fetch', vi.fn(async () => refusal('token_expired')))
  await expect(get('/api/v1/board/reactions')).rejects.toBeInstanceOf(ApiRequestError)
  await vi.waitFor(() => expect(getStoredToken()).toBeNull())
}

let uninstall: () => void = () => undefined

beforeEach(() => {
  resetDevTokenBootstrap()
  uninstall = installRejectedCredentialRecovery()
})

afterEach(() => {
  uninstall()
  vi.unstubAllGlobals()
  window.sessionStorage.clear()
})

describe('a credential the server refused', () => {
  it('drops a pasted token the server called expired and stops sending it', async () => {
    setStoredToken('pasted-token', { source: 'manual' })
    const fetchMock = vi.fn(async (_path: string, _init?: RequestInit) => refusal('token_expired'))
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/runtime-probe')).rejects.toBeInstanceOf(ApiRequestError)

    expect(sentAuthorization(fetchMock.mock.calls[0]?.[1])).toBe('Bearer pasted-token')
    await vi.waitFor(() => expect(getStoredToken()).toBeNull())
    expect(getStoredTokenMeta()).toBeNull()
    expect(authHeaders().Authorization).toBeUndefined()
  })

  it('drops a token refused on a control-plane request too', async () => {
    setStoredToken('url-token', { source: 'url' })
    vi.stubGlobal('fetch', vi.fn(async (path: string) =>
      path === DEV_TOKEN_PATH ? new Response('', { status: 404 }) : refusal('invalid_token')))

    const response = await fetchControlPlane('/api/v1/keepers/chat/stream', {
      method: 'POST',
      headers: jsonHeaders(),
      body: '{}',
    })

    expect(response.status).toBe(401)
    expect(await response.json()).toEqual({ error: 'refused', auth_error_code: 'invalid_token' })
    await vi.waitFor(() => expect(getStoredToken()).toBeNull())
  })

  it('keeps a token stored while the refused request was in flight', async () => {
    setStoredToken('old-token', { source: 'manual' })
    vi.stubGlobal('fetch', vi.fn(async () => {
      setStoredToken('fresh-token', { source: 'manual' })
      return refusal('token_expired')
    }))

    await expect(get('/api/v1/board/reactions')).rejects.toBeInstanceOf(ApiRequestError)
    await settle()

    expect(getStoredToken()).toBe('fresh-token')
    await expectRecoveryStillDropsExpired()
  })

  it('keeps the token when the refusal is about the actor', async () => {
    setStoredToken('pasted-token', { source: 'manual' })
    vi.stubGlobal('fetch', vi.fn(async () => refusal('actor_mismatch')))

    await expect(get('/api/v1/board/reactions')).rejects.toBeInstanceOf(ApiRequestError)
    await settle()

    expect(getStoredToken()).toBe('pasted-token')
    await expectRecoveryStillDropsExpired()
  })

  it('keeps a loopback dev token whose re-mint returns the same value', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async (path: string) =>
      path === DEV_TOKEN_PATH
        ? new Response(JSON.stringify({ token: 'dev-token', actor: 'dashboard', role: 'admin' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
        : refusal('invalid_token'))
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/board/reactions')).rejects.toBeInstanceOf(ApiRequestError)

    await vi.waitFor(() => expect(fetchMock.mock.calls.some(([path]) => path === DEV_TOKEN_PATH)).toBe(true))
    await settle()
    expect(getStoredToken()).toBe('dev-token')
    expect(getStoredTokenMeta()?.source).toBe('dev')
  })

  it('stops acting once recovery is uninstalled', async () => {
    uninstall()
    setStoredToken('pasted-token', { source: 'manual' })
    vi.stubGlobal('fetch', vi.fn(async () => refusal('token_expired')))

    await expect(get('/api/v1/board/reactions')).rejects.toBeInstanceOf(ApiRequestError)
    await settle()

    expect(getStoredToken()).toBe('pasted-token')
  })
})
