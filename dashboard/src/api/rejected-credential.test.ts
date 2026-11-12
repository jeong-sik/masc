import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  authHeaders,
  currentStoredTokenRevision,
  fetchControlPlane,
  get,
  getStoredToken,
  getStoredTokenMeta,
  jsonHeaders,
  setStoredToken,
} from './core'
import { hasPendingDevTokenFailure, devTokenBootstrapStatus, ensureDevToken, installRejectedCredentialRecovery, recoverFromRejectedCredential, recoverScopedRejectedCredential, refreshDevTokenAfterAuthError, resetDevTokenBootstrap, retryRejectedDevToken } from './dev-token'
import { managedDashboardAuthRevision, managedDashboardRefusal, recordManagedCredentialRefusal, setCanonicalDashboardActor } from '../lib/dashboard-session-actor'
import { warmRetryDelayFor } from '../lib/warm-retry'

/* #44189: a tab holding a pasted token the server had stopped accepting kept
   polling `/api/v1/dashboard/runtime-probe` and `/api/v1/board/reactions` with
   it, and the server answered 401 twice a minute for the life of the tab. */

const DEV_TOKEN_PATH = '/api/v1/dashboard/dev-token'
const scopedWorkspace = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }

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
  vi.useRealTimers()
  window.sessionStorage.clear()
})

describe('a credential the server refused', () => {
  it.each([200, 404])('does not let an earlier dev-token %i response change a newer dev token', async status => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveOld!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveOld = resolve })))
    const pending = ensureDevToken()
    setStoredToken('new-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    resolveOld(status === 200
      ? new Response(JSON.stringify({ token: 'stale-response-token', actor: 'dashboard', role: 'admin' }), {
        status, headers: { 'Content-Type': 'application/json' },
      }) : new Response('', { status }))
    await pending
    expect(getStoredToken()).toBe('new-dev-token')
  })

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

  it('recovers a managed 401 after the same dashboard actor is hydrated', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveOld!: (response: Response) => void
    const fetchMock = vi.fn((requestPath: string) => requestPath === DEV_TOKEN_PATH
      ? Promise.resolve(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      : new Promise<Response>(resolve => { resolveOld = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    const pending = get('/api/v1/board/reactions')
    setCanonicalDashboardActor('dashboard')
    resolveOld(refusal('token_expired'))
    await expect(pending).rejects.toBeInstanceOf(ApiRequestError)
    await vi.waitFor(() => expect(getStoredToken()).toBe('fresh-dev-token'))
    expect(fetchMock.mock.calls.filter(([requestPath]) => requestPath === '/api/v1/board/reactions')).toHaveLength(1)
  })

  it.each(['token', 'actor'] as const)('ignores a late refusal after %s changes and returns', async changed => {
    setStoredToken('token-a', { source: 'manual' })
    setCanonicalDashboardActor('actor-a')
    let resolveResponse!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveResponse = resolve })))
    const pending = get('/api/v1/board/reactions')
    if (changed === 'token') {
      setStoredToken('token-b', { source: 'manual' })
      setStoredToken('token-a', { source: 'manual' })
      setCanonicalDashboardActor('actor-a')
    } else {
      setCanonicalDashboardActor('actor-b')
      setCanonicalDashboardActor('actor-a')
    }
    resolveResponse(refusal('token_expired'))
    await expect(pending).rejects.toBeInstanceOf(ApiRequestError)
    await settle()
    expect(getStoredToken()).toBe('token-a')
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

describe('a refusal owned by a Goal request', () => {
  it.each(['http', 'throttled', 'network'] as const)('retries a temporary %s dev-token failure under the same workspace', async kind => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn()
      .mockImplementationOnce(async () => {
        if (kind === 'network') throw new Error('network unavailable')
        return new Response('', { status: kind === 'http' ? 503 : 429 })
      })
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('old-dev-token')
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(String(fetchMock.mock.calls[1]?.[0])).toContain('expected_base_path=%2Fworkspace-a')
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('aborts an in-flight scoped remint when a manual credential replaces its owner', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const signals: AbortSignal[] = []
    const fetchMock = vi.fn((_path: string, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      if (init?.signal) {
        signals.push(init.signal)
        init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
      }
    }))
    vi.stubGlobal('fetch', fetchMock)
    const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    setStoredToken('manual-current', { source: 'manual' })
    await pending
    expect(signals[0]?.aborted).toBe(true)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('manual-current')
  })

  it('does not retry a transient failure after the requesting scope is retired', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async () => new Response('', { status: 503 }))
    vi.stubGlobal('fetch', fetchMock)
    let current = true
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => current, undefined, scopedWorkspace)
    current = false
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('old-dev-token')
  })

  it('does not retry a scoped recovery before the server retry-after time', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response('', { status: 429, headers: { 'Retry-After': '10' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    await expect(retryRejectedDevToken(scopedWorkspace, () => true)).resolves.toBe(false)
    await vi.advanceTimersByTimeAsync(9_999)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('does not automatically retry a valid response returning the same dev token', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ token: 'old-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('retains failed auth read debt beyond ten attempts without replaying the Goal request', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async (_path: string) => new Response('', { status: 503 }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    for (let attempt = 1; attempt <= 12; attempt++) await vi.advanceTimersByTimeAsync(warmRetryDelayFor(attempt))
    expect(fetchMock).toHaveBeenCalledTimes(13)
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(12) * 2)
    expect(fetchMock).toHaveBeenCalledTimes(15)
    expect(fetchMock.mock.calls.every(([path]) => String(path).startsWith(DEV_TOKEN_PATH))).toBe(true)
  })

  it('refuses malformed HTTP200 initialization without polling or dropping its credential', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async () => new Response('{"status":"initializing"}', { headers: { 'content-type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('old-dev-token')
    expect(devTokenBootstrapStatus.value).toBe('invalid_response')
  })

  it('retires the last subscriber retry immediately and keeps newer manual credentials', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn(async () => new Response('', { status: 503 }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    expect(vi.getTimerCount()).toBe(1)
    uninstall()
    expect(vi.getTimerCount()).toBe(0)
    setStoredToken('operator', { source: 'manual' })
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(getStoredToken()).toBe('operator')
  })

  it('allows an explicit retry of a refused token without replaying the Goal request', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response('', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    const current = () => currentStoredTokenRevision() === revision
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      current, undefined, scopedWorkspace)
    await expect(retryRejectedDevToken(scopedWorkspace, current)).resolves.toBe(true)
    expect(getStoredToken()).toBe('fresh-dev-token')
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('keeps an existing scoped recovery when the operator retries while it is in flight', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveRecovery!: (response: Response) => void
    const fetchMock = vi.fn(() => new Promise<Response>(resolve => { resolveRecovery = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    await expect(retryRejectedDevToken(scopedWorkspace, () => true)).resolves.toBe(false)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    resolveRecovery(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await pending
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('retries a transient global recovery without replaying the refused request', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response('', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverFromRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('lets a new managed owner replace an obsolete scheduled recovery', async () => {
    vi.useFakeTimers()
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response('', { status: 503 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
      () => true, undefined, scopedWorkspace)
    setCanonicalDashboardActor('dashboard')
    setCanonicalDashboardActor(null)
    await recoverFromRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' })
    expect(getStoredToken()).toBe('fresh-dev-token')
    await vi.advanceTimersByTimeAsync(warmRetryDelayFor(1))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('records one refusal and attempts one recovery for repeated typed 401s', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    const authRevision = managedDashboardAuthRevision.peek()
    // A shell can first report a refusal without a recoverable error code.
    recordManagedCredentialRefusal(revision)
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({
      token: 'old-dev-token', actor: 'dashboard', role: 'admin',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)
    const rejection = { token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 }
    await recoverScopedRejectedCredential(rejection, () => true, undefined, scopedWorkspace)
    setCanonicalDashboardActor('dashboard')
    setCanonicalDashboardActor(null)
    await recoverScopedRejectedCredential(rejection, () => true, undefined, scopedWorkspace)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(managedDashboardRefusal.peek()).toBe(revision)
    expect(managedDashboardAuthRevision.peek()).toBe(authRevision + 1)
  })

  it('does not classify a tool error or actor mismatch as a refused token', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 503 })))
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'invalid_token', httpStatus: 200 }, () => true, undefined, scopedWorkspace)
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'actor_mismatch', httpStatus: 401 }, () => true, undefined, scopedWorkspace)
    expect(managedDashboardRefusal.peek()).not.toBe(revision)
  })

  it('does not cancel a newer bootstrap started by a refusal subscriber', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const rejectedRevision = currentStoredTokenRevision()
    let resolveBootstrap!: (response: Response) => void
    const fetchMock = vi.fn(() => new Promise<Response>(resolve => { resolveBootstrap = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    let replacement: Promise<void> | null = null
    const stop = managedDashboardRefusal.subscribe(revision => {
      if (revision === rejectedRevision && replacement === null) {
        setStoredToken('new-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
        replacement = ensureDevToken()
      }
    })
    try {
      await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 }, () => true, undefined, scopedWorkspace)
      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(replacement).not.toBeNull()
      resolveBootstrap(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      await replacement
      expect(getStoredToken()).toBe('fresh-dev-token')
    } finally { stop() }
  })

  it.each([200, 404, 503, 'network'] as const)('retires a stale scoped %s recovery claim after bootstrap reset', async status => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let finishOld!: (response: Response) => void
    let failOld!: (error: Error) => void
    const fetchMock = vi.fn()
      .mockImplementationOnce(() => new Promise<Response>((resolve, reject) => { finishOld = resolve; failOld = reject }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)
    const refusal = { token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 }
    const old = recoverScopedRejectedCredential(refusal, () => true, undefined, scopedWorkspace)
    resetDevTokenBootstrap()
    if (status === 'network') failOld(new Error('connection lost'))
    else finishOld(status === 200 ? new Response(JSON.stringify({ token: 'stale-dev-token', actor: 'dashboard', role: 'admin' }), {
      status, headers: { 'Content-Type': 'application/json' },
    }) : new Response('', { status }))
    await old
    expect(getStoredToken()).toBe('old-dev-token')
    await recoverScopedRejectedCredential(refusal, () => true, undefined, scopedWorkspace)
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('does not start an unscoped bootstrap from a refusal subscriber', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const rejectedRevision = currentStoredTokenRevision()
    let resolveBootstrap!: (response: Response) => void
    const fetchMock = vi.fn((_requestPath: string) => new Promise<Response>(resolve => { resolveBootstrap = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    let replacement: Promise<void> | null = null
    const stop = managedDashboardRefusal.subscribe(revision => {
      if (revision === rejectedRevision && replacement === null) replacement = ensureDevToken()
    })
    try {
      const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired', httpStatus: 401 },
        () => true, undefined, scopedWorkspace)
      await replacement
      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(String(fetchMock.mock.calls[0]?.[0])).toContain('expected_base_path=%2Fworkspace-a')
      resolveBootstrap(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      await pending
      expect(getStoredToken()).toBe('fresh-dev-token')
    } finally { stop() }
  })

  it('does not bypass a refused managed token through ordinary bootstrap or readiness polling', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    ;(devTokenBootstrapStatus as { value: string }).value = 'warming'
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    expect(hasPendingDevTokenFailure()).toBe(false)
    await ensureDevToken()
    await expect(refreshDevTokenAfterAuthError('token_expired')).resolves.toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('clears a current expired manual credential', async () => {
    setStoredToken('manual-token', { source: 'manual' })
    await recoverScopedRejectedCredential({ token: 'manual-token', authErrorCode: 'token_expired' }, () => true)
    expect(getStoredToken()).toBeNull()
  })

  it('keeps a manual credential when the actor was refused', async () => {
    setStoredToken('manual-token', { source: 'manual' })
    await recoverScopedRejectedCredential({ token: 'manual-token', authErrorCode: 'actor_mismatch' }, () => true)
    expect(getStoredToken()).toBe('manual-token')
  })

  it.each([
    ['actor_mismatch', 'url-token'],
    ['invalid_token', null],
  ] as const)('does not replace a non-dashboard URL credential after %s', async (code, expected) => {
    setStoredToken('url-token', { source: 'url' })
    setCanonicalDashboardActor('alice')
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    await recoverScopedRejectedCredential({ token: 'url-token', authErrorCode: code }, () => true)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(getStoredToken()).toBe(expected)
  })

  it.each([200, 404])('does not publish a dev-token %i response after its owner changes', async status => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let current = true
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => current, undefined, scopedWorkspace)
    current = false
    resolveFetch(status === 200
      ? new Response(JSON.stringify({ token: 'new-token', actor: 'dashboard', role: 'admin' }), {
        status, headers: { 'Content-Type': 'application/json' },
      }) : new Response('', { status }))
    await pending
    expect(getStoredToken()).toBe('old-dev-token')
  })

  it('installs a renewed dev credential for the same owner', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      token: 'fresh-dev-token', actor: 'dashboard', role: 'admin',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))
    await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => true, undefined, scopedWorkspace)
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it('keeps a managed recovery current when the shell hydrates the same dashboard actor', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => true, undefined, scopedWorkspace)
    setCanonicalDashboardActor('dashboard')
    resolveFetch(new Response(JSON.stringify({ token: 'fresh-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await pending
    expect(getStoredToken()).toBe('fresh-dev-token')
  })

  it.each([200, 404])('does not let an older scoped %s response cancel a newer same-owner bootstrap', async status => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveScoped!: (response: Response) => void
    let resolveBootstrap!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn()
      .mockImplementationOnce(() => new Promise<Response>(resolve => { resolveScoped = resolve }))
      .mockImplementationOnce(() => new Promise<Response>(resolve => { resolveBootstrap = resolve })))
    const scoped = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => true, undefined, scopedWorkspace)
    const bootstrap = ensureDevToken()
    resolveScoped(status === 200
      ? new Response(JSON.stringify({ token: 'stale-token', actor: 'dashboard', role: 'admin' }), {
        status, headers: { 'Content-Type': 'application/json' },
      }) : new Response('', { status }))
    await scoped
    expect(getStoredToken()).toBe('old-dev-token')
    resolveBootstrap(new Response(JSON.stringify({ token: 'fresh-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await bootstrap
    expect(getStoredToken()).toBe('fresh-token')
  })

  it('yields scoped recovery to a bootstrap started synchronously by reset', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveOld!: (response: Response) => void
    let resolveNew!: (response: Response) => void
    const fetchMock = vi.fn()
      .mockImplementationOnce(() => new Promise<Response>(resolve => { resolveOld = resolve }))
      .mockImplementationOnce(() => new Promise<Response>(resolve => { resolveNew = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    const old = ensureDevToken()
    let replacement: Promise<void> | null = null
    const stop = devTokenBootstrapStatus.subscribe(status => {
      if (status === 'idle' && replacement === null) replacement = ensureDevToken()
    })
    try {
      await recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => true, undefined, scopedWorkspace)
      expect(fetchMock).toHaveBeenCalledTimes(2)
      expect(replacement).not.toBeNull()
      resolveNew(new Response(JSON.stringify({ token: 'fresh-token', actor: 'dashboard', role: 'admin' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      await replacement
      resolveOld(new Response('', { status: 404 }))
      await old
      expect(getStoredToken()).toBe('fresh-token')
    } finally {
      stop()
    }
  })

  it('does not publish after the same token is removed and restored', async () => {
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const pending = recoverScopedRejectedCredential({ token: 'old-dev-token', authErrorCode: 'token_expired' }, () => true, undefined, scopedWorkspace)
    setStoredToken('other-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    resolveFetch(new Response(JSON.stringify({ token: 'stale-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await pending
    expect(getStoredToken()).toBe('old-dev-token')
  })
})
