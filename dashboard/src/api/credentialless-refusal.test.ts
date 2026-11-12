import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, get, setStoredToken } from './core'
import { ensureDevToken } from './dev-token'
import { credentiallessRequest, noteRefusal, replayedRefusal } from './credentialless-refusal'

const missingToken = () => new Response(
  '{"error":"Authentication required","auth_error_code":"missing_token"}',
  { status: 401, headers: { 'Content-Type': 'application/json' } },
)

const ok = () => new Response('{"status":"ok"}', {
  status: 200,
  headers: { 'Content-Type': 'application/json' },
})

function sentAuthorization(fetchMock: ReturnType<typeof vi.fn>, index: number): string | null {
  const call = fetchMock.mock.calls[index]
  if (call === undefined) throw new Error(`fetch call ${index} was not made`)
  const init = call[1] as RequestInit
  return new Headers(init.headers).get('Authorization')
}

afterEach(() => {
  vi.unstubAllGlobals()
  window.sessionStorage?.clear?.()
})

// Each test uses its own route: the table lives for the page, as it does in
// the dashboard, so routes keep tests apart.
describe('a request without a credential that the server refused', () => {
  it('does not memoize a refusal whose delayed body finished after cancellation', async () => {
    const request = credentiallessRequest('GET', '/cancelled-credentialless-read', 0)
    const response = missingToken()
    let finish!: (value: string) => void
    vi.spyOn(response, 'text').mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const caller = new AbortController()
    const pending = noteRefusal(request, response, caller.signal)
    caller.abort()
    finish('{"auth_error_code":"missing_token"}')
    await pending
    expect(replayedRefusal(request)).toBeNull()
  })

  it('is answered with the same refusal without being sent again', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => missingToken())
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/telemetry')).rejects.toMatchObject({ status: 401, authErrorCode: 'missing_token' })
    await expect(get('/api/v1/dashboard/telemetry?window=1h')).rejects.toMatchObject({ status: 401, authErrorCode: 'missing_token' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('is sent again with the credential once a dev token is stored', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce(async () => missingToken())
      .mockImplementation(async () => ok())
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/shell')).rejects.toMatchObject({ status: 401 })
    setStoredToken('managed-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    await expect(get('/api/v1/dashboard/shell')).resolves.toEqual({ status: 'ok' })

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(sentAuthorization(fetchMock, 1)).toBe('Bearer managed-token')
  })

  it('is sent again without a credential after a token was stored and cleared', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce(async () => missingToken())
      .mockImplementation(async () => ok())
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/goals')).rejects.toMatchObject({ status: 401 })
    setStoredToken('manual-token')
    clearStoredToken()
    await expect(get('/api/v1/dashboard/goals')).resolves.toEqual({ status: 'ok' })

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(sentAuthorization(fetchMock, 1)).toBeNull()
  })

  it('does not hold back another route or a refusal with another code', async () => {
    const fetchMock = vi.fn()
      .mockImplementationOnce(async () => missingToken())
      .mockImplementationOnce(async () => new Response('{"error":"Origin not allowed","auth_error_code":"same_origin_blocked"}', { status: 401 }))
      .mockImplementation(async () => ok())
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/planning')).rejects.toMatchObject({ status: 401 })
    await expect(get('/api/v1/dashboard/briefing')).rejects.toMatchObject({ status: 401 })
    await expect(get('/api/v1/dashboard/briefing')).resolves.toEqual({ status: 'ok' })

    expect(fetchMock).toHaveBeenCalledTimes(3)
  })

  it('does not hold back a route the server answered without a credential', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => ok())
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/agents')).resolves.toEqual({ status: 'ok' })
    await expect(get('/api/v1/agents')).resolves.toEqual({ status: 'ok' })

    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('is sent with the dev token that a retried bootstrap stored', async () => {
    const devTokenAnswers = [
      new Response('{"status":"initializing"}', { status: 503, headers: { 'Content-Type': 'application/json' } }),
      new Response('{"token":"dev-token-1","actor":"dashboard","role":"admin"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ]
    const fetchMock = vi.fn().mockImplementation(async (path: string, init: RequestInit) => {
      if (path !== '/api/v1/dashboard/dev-token') {
        return new Headers(init.headers).has('Authorization') ? ok() : missingToken()
      }
      const answer = devTokenAnswers.shift()
      if (answer === undefined) throw new Error('dev-token asked more than twice')
      return answer
    })
    vi.stubGlobal('fetch', fetchMock)

    await ensureDevToken()
    await expect(get('/api/v1/dashboard/keepers')).rejects.toMatchObject({ status: 401, authErrorCode: 'missing_token' })
    await ensureDevToken()
    await expect(get('/api/v1/dashboard/keepers')).resolves.toEqual({ status: 'ok' })

    const keeperCalls = fetchMock.mock.calls.flatMap((call, index) => call[0] === '/api/v1/dashboard/keepers' ? [index] : [])
    expect(keeperCalls).toHaveLength(2)
    expect(sentAuthorization(fetchMock, keeperCalls[1] ?? -1)).toBe('Bearer dev-token-1')
  })
})
