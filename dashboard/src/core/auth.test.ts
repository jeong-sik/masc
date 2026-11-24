import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { startNavTelemetry } from '../lib/nav-telemetry'
import type { RouteState } from '../types'
import {
  activeWorkspaceId,
  authSession,
  bootstrapAuthSession,
  bumpSessionEpoch,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  installAuthLifecycleGuards,
  isAuthenticated,
  isEpochCurrent,
  refreshMultiAccountCsrf,
  registerWorkspaceTargets,
  resetAuthStateForTests,
  resolveWorkspaceUrl,
  selectWorkspace,
  sessionEpoch,
  setSingleUserToken,
  wipeTransientSecrets,
  workspaceTargets,
} from './auth'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('core/auth', () => {
  beforeEach(() => {
    resetAuthStateForTests()
  })

  afterEach(() => {
    resetAuthStateForTests()
  })

  it('defaults to single_user when /health omits account_mode and never probes dev-token unless advertised', async () => {
    const calls: string[] = []
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      calls.push(url)
      if (url === '/health') return jsonResponse({ status: 'ok' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ ok: true })
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('single_user_local')
    expect(isAuthenticated.value).toBe(true)
    expect(calls).toEqual(['/health', '/api/v1/dashboard/shell'])
    expect(calls).not.toContain('/api/v1/dashboard/dev-token')
  })

  it('probes /api/v1/dashboard/dev-token ONLY when health.auth_methods.dev_token === true', async () => {
    const calls: string[] = []
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      calls.push(url)
      if (url === '/health') {
        return jsonResponse({ status: 'ok', account_mode: null, auth_methods: { dev_token: true } })
      }
      if (url === '/api/v1/dashboard/dev-token') {
        return jsonResponse({ token: 'dev-placeholder-val' })
      }
      if (url === '/api/v1/dashboard/shell') {
        const hdrs = init?.headers as Record<string, string>
        expect(hdrs.Authorization).toBe('Bearer dev-placeholder-val')
        return jsonResponse({ ok: true })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('single_user_local')
    if (session.kind === 'single_user_local') {
      expect(session.tokenPresent).toBe(true)
    }
    expect(getSingleUserToken()).toBe('dev-placeholder-val')
    expect(calls).toEqual(['/health', '/api/v1/dashboard/dev-token', '/api/v1/dashboard/shell'])
  })

  it('transitions to single_user_auth_required on 401 and unavailable on 5xx from shell probe', async () => {
    const authReqFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ status: 'ok' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ error: 'unauthorized' }, 401)
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: authReqFetch as unknown as typeof fetch })
    expect(session.kind).toBe('single_user_auth_required')
    expect(isAuthenticated.value).toBe(false)

    // 503 during engine startup must fail closed to unavailable, NEVER single_user_local
    resetAuthStateForTests()
    const unavailableFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ status: 'ok' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ error: 'engine_starting' }, 503)
      throw new Error(`unexpected url: ${url}`)
    })
    const down = await bootstrapAuthSession({ fetchImpl: unavailableFetch as unknown as typeof fetch })
    expect(down.kind).toBe('unavailable')
    expect(isAuthenticated.value).toBe(false)
  })

  it('reads live OCaml GET /auth/session + GET /api/v1/auth/whoami for Multi_account Admin/Worker/signed-out', async () => {
    const calls: string[] = []
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      calls.push(url)
      if (url === '/health') {
        return jsonResponse({
          status: 'ok',
          account_mode: 'Multi_account',
          auth_methods: { google: true, github: true, dev_token: false },
        })
      }
      if (url === '/auth/session') {
        return jsonResponse({
          user_id: 'usr-alice',
          expires_at_ms: 1_800_000_000_000,
          csrf_token: 'csrf-val-1',
        })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({
          principal: { kind: 'human', id: 'usr-alice' },
          role: 'admin',
          binding: { kind: 'browser_session' },
        })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('multi_account_signed_in')
    if (session.kind === 'multi_account_signed_in') {
      expect(session.accountId).toBe('usr-alice')
      expect(session.role).toBe('admin')
      expect(session.csrfToken).toBe('csrf-val-1')
    }
    expect(getActiveCsrfToken()).toBe('csrf-val-1')
    expect(calls).toEqual(['/health', '/auth/session', '/api/v1/auth/whoami'])
    expect(calls).not.toContain('/api/v1/dashboard/dev-token')

    // Worker role + unknown role fail-closed to 'viewer'
    resetAuthStateForTests()
    const workerFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') return jsonResponse({ user_id: 'usr-bob', expires_at_ms: 1, csrf_token: 'csrf-b' })
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'human', id: 'usr-bob' }, role: 'worker' })
      }
      throw new Error(`unexpected url: ${url}`)
    })
    const workerSession = await bootstrapAuthSession({ fetchImpl: workerFetch as unknown as typeof fetch })
    expect(workerSession.kind).toBe('multi_account_signed_in')
    if (workerSession.kind === 'multi_account_signed_in') {
      expect(workerSession.role).toBe('worker')
    }

    // Signed-out transition (401 on GET /auth/session)
    resetAuthStateForTests()
    const signedOutFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'multi_account' })
      if (url === '/auth/session') return jsonResponse({ error: 'credential_required' }, 401)
      throw new Error(`unexpected url: ${url}`)
    })
    const out = await bootstrapAuthSession({ fetchImpl: signedOutFetch as unknown as typeof fetch })
    expect(out.kind).toBe('multi_account_signed_out')
    expect(isAuthenticated.value).toBe(false)
  })

  it.each(['/auth/session', '/api/v1/auth/whoami'])(
    'reports a malformed %s response without surfacing the JSON parser exception',
    async (malformedPath) => {
      const fetchMock: typeof fetch = async (input) => {
        const url = String(input)
        if (url === malformedPath) return new Response('{ invalid json')
        if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
        if (url === '/auth/session') return jsonResponse({ user_id: 'acct-1', csrf_token: 'csrf-1' })
        throw new Error(`unexpected url: ${url}`)
      }
      const session = await bootstrapAuthSession({ fetchImpl: fetchMock })
      expect(session).toEqual({ kind: 'unavailable', reason: `GET ${malformedPath} returned malformed payload` })
      expect(getActiveCsrfToken()).toBeNull()
    },
  )

  it('rejects non-human principals and detects mid-bootstrap session/whoami user_id mismatch', async () => {
    const servicePrincipalFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') return jsonResponse({ user_id: 'usr-1', csrf_token: 'c1' })
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'service_credential', id: 'svc-1' }, role: 'worker' })
      }
      throw new Error(`unexpected url: ${url}`)
    })
    const rejected = await bootstrapAuthSession({ fetchImpl: servicePrincipalFetch as unknown as typeof fetch })
    expect(rejected.kind).toBe('unavailable')

    resetAuthStateForTests()
    const epochBefore = currentSessionEpoch()
    const mismatchFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') return jsonResponse({ user_id: 'usr-1', csrf_token: 'c1' })
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'human', id: 'usr-2' }, role: 'admin' })
      }
      throw new Error(`unexpected url: ${url}`)
    })
    const drifted = await bootstrapAuthSession({ fetchImpl: mismatchFetch as unknown as typeof fetch })
    expect(drifted.kind).toBe('account_changed')
    expect(currentSessionEpoch()).toBe(epochBefore + 1)
  })

  it('fails closed to unavailable on unknown account_mode', async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ account_mode: 'future_mode_v9' }))
    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('unavailable')
  })

  it('increments monotonic sessionEpoch on workspace switch, token update, and enforces same-origin baseUrl', async () => {
    const epoch0 = currentSessionEpoch()
    registerWorkspaceTargets([
      { id: 'ws-1', label: 'Workspace 1', baseUrl: '/ws/one/' },
      { id: 'ws-2', label: 'Workspace 2', baseUrl: 'https://evil.example.invalid/ws' },
    ])
    expect(workspaceTargets.value).toHaveLength(2)
    expect(activeWorkspaceId.value).toBe('ws-1')
    expect(resolveWorkspaceUrl('/api/v1/dashboard/shell')).toBe('/ws/one/api/v1/dashboard/shell')
    expect(sessionEpoch.value).toBeGreaterThan(epoch0)

    const epoch1 = currentSessionEpoch()
    expect(selectWorkspace('ws-2')).toBe(true)
    expect(selectWorkspace('ws-2')).toBe(false) // idempotent
    expect(currentSessionEpoch()).toBe(epoch1 + 1)
    expect(isEpochCurrent(epoch1)).toBe(false)
    // Cross-origin baseUrl is refused fail-closed so cookies/CSRF stay same-origin
    expect(resolveWorkspaceUrl('/api/v1/dashboard/shell')).toBe('/api/v1/dashboard/shell')

    const epoch2 = currentSessionEpoch()
    setSingleUserToken('local-val-1')
    expect(currentSessionEpoch()).toBe(epoch2 + 1)

    const epoch3 = bumpSessionEpoch()
    expect(epoch3).toBe(epoch2 + 2)
  })

  it('detects cross-tab account switch via storage event and wipes secrets on pagehide', async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') {
        return jsonResponse({ user_id: 'acct-1', expires_at_ms: 1, csrf_token: 'csrf-initial' })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'human', id: 'acct-1' }, role: 'worker' })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    const epochBefore = currentSessionEpoch()
    const dispose = installAuthLifecycleGuards(fetchMock as unknown as typeof fetch)

    try {
      const storageEvt = new StorageEvent('storage', {
        key: 'masc.core.account_marker',
        oldValue: 'acct-1',
        newValue: 'acct-2',
      })
      window.dispatchEvent(storageEvt)

      expect(authSession.value.kind).toBe('account_changed')
      if (authSession.value.kind === 'account_changed') {
        expect(authSession.value.previousAccountId).toBe('acct-1')
        expect(authSession.value.nextAccountId).toBe('acct-2')
      }
      expect(currentSessionEpoch()).toBe(epochBefore + 1)
      expect(getActiveCsrfToken()).toBeNull()

      setSingleUserToken('ephemeral-val')
      expect(getSingleUserToken()).toBe('ephemeral-val')
      window.dispatchEvent(new Event('pagehide'))
      expect(getSingleUserToken()).toBeNull()
    } finally {
      dispose()
      wipeTransientSecrets()
    }
  })

  it('bumps sessionEpoch and exits signed-in state on visibilitychange when session expires or workspace_id drifts', async () => {
    let sessionAlive = true
    let serverWorkspace = 'ws-initial'
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') {
        if (!sessionAlive) return jsonResponse({ error: 'expired' }, 401)
        return jsonResponse({ user_id: 'acct-vis', expires_at_ms: 1, csrf_token: 'csrf-vis' })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({
          principal: { kind: 'human', id: 'acct-vis' },
          role: 'admin',
          workspace_id: serverWorkspace,
        })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    const epoch0 = currentSessionEpoch()
    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(activeWorkspaceId.value).toBe('ws-initial')
    expect(currentSessionEpoch()).toBe(epoch0 + 1)

    const dispose = installAuthLifecycleGuards(fetchMock as unknown as typeof fetch)
    try {
      // Server expires session while tab was hidden
      sessionAlive = false
      const epochBeforeVis = currentSessionEpoch()
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
      document.dispatchEvent(new Event('visibilitychange'))
      await new Promise((r) => setTimeout(r, 0))

      expect(authSession.value.kind).toBe('account_changed')
      expect(currentSessionEpoch()).toBe(epochBeforeVis + 1)
      expect(getActiveCsrfToken()).toBeNull()
    } finally {
      dispose()
      wipeTransientSecrets()
    }
  })

  it('refreshes CSRF token via GET /auth/session + whoami and detects account drift', async () => {
    let csrfCounter = 1
    let accountId = 'acct-1'
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/auth/session') {
        return jsonResponse({
          user_id: accountId,
          expires_at_ms: 1_800_000_000_000,
          csrf_token: `csrf-rev-${csrfCounter++}`,
        })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({ principal: { kind: 'human', id: accountId }, role: 'admin' })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(getActiveCsrfToken()).toBe('csrf-rev-1')

    const refreshed = await refreshMultiAccountCsrf(fetchMock as unknown as typeof fetch)
    expect(refreshed).toBe('csrf-rev-2')
    expect(getActiveCsrfToken()).toBe('csrf-rev-2')

    accountId = 'acct-other'
    const epochBefore = currentSessionEpoch()
    const afterDrift = await refreshMultiAccountCsrf(fetchMock as unknown as typeof fetch)
    expect(afterDrift).toBeNull()
    expect(authSession.value.kind).toBe('account_changed')
    expect(currentSessionEpoch()).toBe(epochBefore + 1)
  })

  it('gates nav-telemetry POSTs while unauthenticated (0x 401 on boot/sign-out)', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse({ ok: true }))
    const routeSig = signal<RouteState>({ tab: 'overview', params: {}, postId: null })
    const dispose = startNavTelemetry({ routeSignal: routeSig })
    try {
      expect(fetchSpy).not.toHaveBeenCalled()

      authSession.value = {
        kind: 'multi_account_signed_out',
        mode: 'multi_account',
        authMethods: { google: true, github: false, dev_token: false },
      }
      routeSig.value = { tab: 'keepers', params: { section: 'keepers' }, postId: null }
      expect(fetchSpy).not.toHaveBeenCalled()

      authSession.value = {
        kind: 'multi_account_signed_in',
        mode: 'multi_account',
        accountId: 'acct-1',
        email: null,
        displayName: 'Alice',
        role: 'admin',
        csrfToken: 'csrf-nav-1',
        authMethods: { google: true, github: false, dev_token: false },
        workspaceId: 'default',
      }
      routeSig.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
      expect(fetchSpy).toHaveBeenCalledTimes(1)
      const [url, init] = fetchSpy.mock.calls[0]!
      expect(url).toBe('/api/v1/dashboard/nav-event')
      expect((init?.headers as Record<string, string>)['x-masc-csrf-token']).toBe('csrf-nav-1')
    } finally {
      dispose()
      fetchSpy.mockRestore()
    }
  })
})
