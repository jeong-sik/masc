import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, get, setStoredToken } from './core'

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
})
