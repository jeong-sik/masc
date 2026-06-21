import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  devTokenBootstrapStatus,
  ensureDevToken,
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
        scope: 'admin',
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
      scope: 'admin',
    })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('keeps a successful bootstrap memoized for the page load', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'loopback-dev-token',
      actor: 'dashboard',
      scope: 'admin',
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
})
