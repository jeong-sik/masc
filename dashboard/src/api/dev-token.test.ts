import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  devTokenBootstrapStatus,
  hasPendingDevTokenFailure,
  ensureDevToken,
  recoverFromRejectedCredential,
  refreshDevTokenAfterAuthError,
  resetDevTokenBootstrap,
  type DevTokenBootstrapStatus,
} from './dev-token'
import { setCanonicalDashboardActor } from '../lib/dashboard-session-actor'

const {
  clearStoredToken,
  currentDashboardActor,
  currentStoredTokenRevision,
  fetchWithTimeout,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
} = vi.hoisted(() => ({
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn(),
  currentStoredTokenRevision: vi.fn(() => 0),
  fetchWithTimeout: vi.fn(),
  getStoredToken: vi.fn(),
  getStoredTokenMeta: vi.fn(),
  isRemoteAccess: vi.fn(),
  setStoredToken: vi.fn(),
}))

vi.mock('./core', () => ({
  clearStoredToken,
  currentDashboardActor,
  currentStoredTokenRevision,
  fetchWithTimeout: (path: string, init: RequestInit, timeout: number, consume?: (res: Response) => Promise<unknown>) => {
    const response = fetchWithTimeout(path, init, timeout, consume)
    return consume ? Promise.resolve(response).then(consume) : response
  },
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
    currentStoredTokenRevision.mockReset().mockReturnValue(0)
    resetDevTokenBootstrap()
    setBootstrapStatus('idle')
    getStoredToken.mockReturnValue(null)
    getStoredTokenMeta.mockReturnValue(null)
    currentDashboardActor.mockReturnValue('dashboard')
    isRemoteAccess.mockReturnValue(false)
  })

  afterEach(() => {
    setCanonicalDashboardActor(null)
    vi.useRealTimers()
  })

  it('marks a JSON null token response invalid', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse(null))
    await ensureDevToken()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
    expect(setStoredToken).not.toHaveBeenCalled()
  })

  it('withdraws a reset bootstrap without letting its late response replace a newer one', async () => {
    let finishOld!: (response: Response) => void
    let finishNew!: (response: Response) => void
    fetchWithTimeout.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { finishNew = resolve }))
    const old = ensureDevToken()
    expect(devTokenBootstrapStatus.value).toBe('fetching')
    resetDevTokenBootstrap()
    expect(devTokenBootstrapStatus.value).toBe('idle')
    const current = ensureDevToken()
    finishOld(jsonResponse({ token: 'stale', actor: 'dashboard', role: 'admin' }))
    await old
    expect(devTokenBootstrapStatus.value).toBe('fetching')
    expect(setStoredToken).not.toHaveBeenCalled()
    finishNew(jsonResponse({ token: 'current', actor: 'dashboard', role: 'admin' }))
    await current
    expect(setStoredToken).toHaveBeenCalledOnce()
    expect(setStoredToken).toHaveBeenCalledWith('current', { source: 'dev', actor: 'dashboard', role: 'admin' })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('restarts once for a changed owner that still permits dashboard bootstrap', async () => {
    let finishOld!: (response: Response) => void
    fetchWithTimeout.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
      .mockResolvedValueOnce(jsonResponse({ token: 'current', actor: 'dashboard', role: 'admin' }))
    const pending = ensureDevToken()
    setCanonicalDashboardActor('alice')
    setCanonicalDashboardActor(null)
    finishOld(jsonResponse({ token: 'stale', actor: 'dashboard', role: 'admin' }))
    await pending
    expect(fetchWithTimeout).toHaveBeenCalledTimes(2)
    expect(setStoredToken).toHaveBeenCalledOnce()
    expect(setStoredToken).toHaveBeenCalledWith('current', { source: 'dev', actor: 'dashboard', role: 'admin' })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('does not replace an explicitly selected non-dashboard actor after an owner change', async () => {
    let finishOld!: (response: Response) => void
    fetchWithTimeout.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    const pending = ensureDevToken()
    currentDashboardActor.mockReturnValue('alice')
    finishOld(jsonResponse({ token: 'stale', actor: 'dashboard', role: 'admin' }))
    await pending
    expect(fetchWithTimeout).toHaveBeenCalledOnce()
    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('idle')
  })

  it('does not bootstrap a selected actor even if old dev metadata remains without a token', async () => {
    getStoredToken.mockReturnValue(null)
    getStoredTokenMeta.mockReturnValue({ source: 'dev', actor: 'dashboard', role: 'admin' })
    setCanonicalDashboardActor('alice')
    await ensureDevToken()
    expect(fetchWithTimeout).not.toHaveBeenCalled()
    expect(setStoredToken).not.toHaveBeenCalled()
  })

  it('does not request a loopback development token from a remote browser', async () => {
    isRemoteAccess.mockReturnValue(true)
    await ensureDevToken()
    expect(fetchWithTimeout).not.toHaveBeenCalled()
    expect(setStoredToken).not.toHaveBeenCalled()
  })

  it('treats producer-less HTTP200 initializing as malformed until an explicit reset', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(jsonResponse({
        status: 'initializing',
        message: 'Server is warming up',
      }))
      .mockResolvedValueOnce(jsonResponse({
        token: 'ready-dev-token',
        actor: 'dashboard',
        role: 'admin',
      }))

    await ensureDevToken()
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
    expect(hasPendingDevTokenFailure()).toBe(false)

    await ensureDevToken()
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    resetDevTokenBootstrap()
    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(2)
    expect(setStoredToken).toHaveBeenCalledWith('ready-dev-token', {
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it.each([429, 503])(
    'retains HTTP %s as a failed read without pinning the in-flight promise',
    async status => {
      fetchWithTimeout
        .mockResolvedValueOnce(new Response('not ready', { status }))
        .mockResolvedValueOnce(jsonResponse({
          token: 'ready-dev-token',
          actor: 'dashboard',
          role: 'admin',
        }))

      await ensureDevToken()
      expect(devTokenBootstrapStatus.value).toBe('warming')
      expect(hasPendingDevTokenFailure()).toBe(true)

      await ensureDevToken()
      expect(fetchWithTimeout).toHaveBeenCalledTimes(2)
      expect(devTokenBootstrapStatus.value).toBe('ok')
    },
  )

  it.each([408, 425, 500])('does not keep retrying terminal HTTP %s token issuance', async status => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('refused', { status }))
    await ensureDevToken()
    await ensureDevToken()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
    expect(hasPendingDevTokenFailure()).toBe(false)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })

  it('marks malformed JSON unavailable instead of retryable network failure', async () => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('{broken', { headers: { 'content-type': 'application/json' } }))
    await ensureDevToken()
    await ensureDevToken()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
    expect(hasPendingDevTokenFailure()).toBe(false)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })

  it('does not overwrite a manual token entered while the server is warming', async () => {
    vi.useFakeTimers()
    let token: string | null = null
    let meta: { source: 'manual' } | null = null
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    fetchWithTimeout
      .mockResolvedValueOnce(jsonResponse({ status: 'initializing' }))

    const bootstrap = ensureDevToken()
    await Promise.resolve()
    token = 'operator-token'
    meta = { source: 'manual' }
    await vi.advanceTimersByTimeAsync(1_000)
    await bootstrap

    expect(setStoredToken).not.toHaveBeenCalled()
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(token).toBe('operator-token')
  })

  it('allows a later explicit bootstrap after a network failure', async () => {
    fetchWithTimeout
      .mockRejectedValueOnce(new Error('server not ready'))
      .mockResolvedValueOnce(jsonResponse({
        token: 'fresh-dev-token',
        actor: 'dashboard',
        role: 'admin',
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
      role: 'admin',
    })
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('keeps a successful bootstrap memoized for the page load', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'loopback-dev-token',
      actor: 'dashboard',
      role: 'admin',
    }))

    await ensureDevToken()
    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).toHaveBeenCalledTimes(1)
    expect(devTokenBootstrapStatus.value).toBe('ok')
  })

  it('memoizes a disabled loopback dev-token endpoint as terminal', async () => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('not found', { status: 404 }))

    await ensureDevToken()
    await ensureDevToken()

    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('no_endpoint')
  })

  it('rejects a bootstrap response without the exact admin identity contract', async () => {
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'stale-worker-token',
      actor: 'dashboard',
      role: 'worker',
    }))

    await ensureDevToken()

    expect(setStoredToken).not.toHaveBeenCalled()
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
  })

  it('refreshes a managed loopback token only for a typed refreshable auth code', async () => {
    let token: string | null = 'stale-token'
    let revision = 0
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = {
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    }
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    currentStoredTokenRevision.mockImplementation(() => revision)
    clearStoredToken.mockImplementation(() => {
      token = null
      meta = null
    })
    setStoredToken.mockImplementation((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
      revision += 1
    })
    fetchWithTimeout.mockResolvedValueOnce(jsonResponse({
      token: 'fresh-token',
      actor: 'dashboard',
      role: 'admin',
    }))

    await expect(refreshDevTokenAfterAuthError('invalid_token')).resolves.toBe(true)
    expect(token).toBe('fresh-token')
    // Recovery replaces the token in place. Clearing first would be a second
    // token-revision change, and each one re-dials the dashboard websocket.
    expect(clearStoredToken).not.toHaveBeenCalled()
    expect(setStoredToken).toHaveBeenCalledTimes(1)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)

    await expect(refreshDevTokenAfterAuthError('insufficient_role')).resolves.toBe(false)
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })

  it('coalesces concurrent stale-token recovery onto one refresh', async () => {
    let token: string | null = 'stale-token'
    let revision = 0
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = {
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    }
    let resolveFetch!: (response: Response) => void
    const pendingFetch = new Promise<Response>((resolve) => {
      resolveFetch = resolve
    })
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    currentStoredTokenRevision.mockImplementation(() => revision)
    clearStoredToken.mockImplementation(() => {
      token = null
      meta = null
    })
    setStoredToken.mockImplementation((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
      revision += 1
    })
    fetchWithTimeout.mockReturnValueOnce(pendingFetch)

    const first = refreshDevTokenAfterAuthError('invalid_token')
    const second = refreshDevTokenAfterAuthError('token_expired')
    expect(clearStoredToken).not.toHaveBeenCalled()
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)

    resolveFetch(jsonResponse({
      token: 'fresh-token',
      actor: 'dashboard',
      role: 'admin',
    }))

    await expect(Promise.all([first, second])).resolves.toEqual([true, true])
    expect(token).toBe('fresh-token')
  })

  // A rejection the token cannot fix (server-side identity or policy) hands
  // back the same credential. Calling that "recovered" makes the caller retry
  // the identical request and refresh again on the identical failure, and
  // every pass re-dials the websocket.
  it('does not report recovery when the endpoint returns the same token', async () => {
    let token: string | null = 'current-token'
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = {
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
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
      token: 'current-token',
      actor: 'dashboard',
      role: 'admin',
    }))

    await expect(refreshDevTokenAfterAuthError('invalid_token')).resolves.toBe(false)
    expect(token).toBe('current-token')
    // Unchanged credential, so nothing may announce a token change.
    expect(setStoredToken).not.toHaveBeenCalled()
    expect(clearStoredToken).not.toHaveBeenCalled()
  })
})

describe('recoverFromRejectedCredential on a remote host', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    resetDevTokenBootstrap()
    isRemoteAccess.mockReturnValue(true)
    currentDashboardActor.mockReturnValue('dashboard')
  })

  it('drops a refused token because no dev token can replace it there', async () => {
    getStoredToken.mockReturnValue('remote-token')
    getStoredTokenMeta.mockReturnValue({ source: 'dev', actor: 'dashboard', role: 'admin' })

    await recoverFromRejectedCredential({ token: 'remote-token', authErrorCode: 'token_expired' })

    expect(fetchWithTimeout).not.toHaveBeenCalled()
    expect(clearStoredToken).toHaveBeenCalledTimes(1)
  })

  it('leaves a token that is no longer the refused one', async () => {
    getStoredToken.mockReturnValue('newer-token')
    getStoredTokenMeta.mockReturnValue({ source: 'manual' })

    await recoverFromRejectedCredential({ token: 'remote-token', authErrorCode: 'invalid_token' })

    expect(clearStoredToken).not.toHaveBeenCalled()
  })
})
