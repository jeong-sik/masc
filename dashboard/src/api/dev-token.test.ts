import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  devTokenBootstrapStatus,
  ensureDevToken,
  refreshDevTokenAfterAuthError,
  resetDevTokenBootstrap,
  type DevTokenBootstrapStatus,
} from './dev-token'

const {
  clearStoredToken,
  currentDashboardActor,
  fetchWithTimeout,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
} = vi.hoisted(() => ({
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn(),
  fetchWithTimeout: vi.fn(),
  getStoredToken: vi.fn(),
  getStoredTokenMeta: vi.fn(),
  isRemoteAccess: vi.fn(),
  setStoredToken: vi.fn(),
}))

vi.mock('./core', () => ({
  clearStoredToken,
  currentDashboardActor,
  fetchWithTimeout,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
}))

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function setBootstrapStatus(value: DevTokenBootstrapStatus): void {
  ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = value
}

describe('ensureDevToken', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    resetDevTokenBootstrap()
    setBootstrapStatus('idle')
    getStoredToken.mockReturnValue(null)
    getStoredTokenMeta.mockReturnValue(null)
    currentDashboardActor.mockReturnValue('dashboard')
    isRemoteAccess.mockReturnValue(false)
  })

  it('retries after a transient network bootstrap failure in the same page load', async () => {
    fetchWithTimeout
      .mockRejectedValueOnce(new Error('server not ready'))
      .mockResolvedValueOnce(jsonResponse({
        token: 'fresh-dev-token',
        actor: 'dashboard',
        role: 'worker',
      }))

    await ensureDevToken()
    expect(devTokenBootstrapStatus.value).toBe('network')
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).not.toHaveBeenCalled()

    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(2)
    expect(setStoredToken).toHaveBeenCalledWith('fresh-dev-token', {
      source: 'dev',
      actor: 'dashboard',
      role: 'worker',
    })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('keeps a successful bootstrap memoized for the page load', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'loopback-dev-token',
      actor: 'dashboard',
      role: 'worker',
    }))

    await ensureDevToken()
    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).toHaveBeenCalledTimes(1)
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('does not keep retrying a disabled loopback dev-token endpoint', async () => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('not found', { status: 404 }))

    await ensureDevToken()
    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('no_endpoint')
  })

  it('rejects a bootstrap response without the exact worker identity contract', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'overprivileged-token',
      actor: 'dashboard',
      role: 'admin',
    }))

    await ensureDevToken()

    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
  })

  it('refreshes a managed loopback token only for a typed refreshable auth code', async () => {
    let token: string | null = 'stale-token'
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'worker' } | null = {
      source: 'dev',
      actor: 'dashboard',
      role: 'worker',
    }
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    clearStoredToken.mockImplementation(() => {
      token = null
      meta = null
    })
    setStoredToken.mockImplementation((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
    })
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'fresh-token',
      actor: 'dashboard',
      role: 'worker',
    }))

    await expect(refreshDevTokenAfterAuthError('invalid_token')).resolves.toBe(true)
    expect(token).toBe('fresh-token')
    expect(clearStoredToken).toHaveBeenCalledTimes(1)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)

    await expect(refreshDevTokenAfterAuthError('insufficient_role')).resolves.toBe(false)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })
})
