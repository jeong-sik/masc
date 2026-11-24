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

  it('transitions to single_user_auth_required on 401 from shell probe', async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ status: 'ok' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ error: 'unauthorized' }, 401)
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('single_user_auth_required')
    expect(isAuthenticated.value).toBe(false)
  })

  it('handles PascalCase Multi_account signed-in and signed-out sessions without calling dev-token', async () => {
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
      if (url === '/api/v1/auth/session') {
        return jsonResponse({
          authenticated: true,
          account_id: 'acct-alice',
          email: 'alice@example.test',
          display_name: 'Alice',
          role: 'Admin',
          csrf_token: 'csrf-val-1',
          workspace_id: 'ws-alpha',
        })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('multi_account_signed_in')
    if (session.kind === 'multi_account_signed_in') {
      expect(session.accountId).toBe('acct-alice')
      expect(session.role).toBe('admin')
      expect(session.workspaceId).toBe('ws-alpha')
    }
    expect(getActiveCsrfToken()).toBe('csrf-val-1')
    expect(activeWorkspaceId.value).toBe('ws-alpha')
    expect(calls).not.toContain('/api/v1/dashboard/dev-token')

    // Signed-out transition
    resetAuthStateForTests()
    const signedOutFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'multi_account' })
      if (url === '/api/v1/auth/session') return jsonResponse({ authenticated: false }, 401)
      throw new Error(`unexpected url: ${url}`)
    })
    const out = await bootstrapAuthSession({ fetchImpl: signedOutFetch as unknown as typeof fetch })
    expect(out.kind).toBe('multi_account_signed_out')
    expect(isAuthenticated.value).toBe(false)
  })

  it('fails closed to unavailable on unknown account_mode', async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ account_mode: 'future_mode_v9' }))
    const session = await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(session.kind).toBe('unavailable')
  })

  it('increments monotonic sessionEpoch on workspace switch, token update, and account change', async () => {
    const epoch0 = currentSessionEpoch()
    registerWorkspaceTargets([
      { id: 'ws-1', label: 'Workspace 1' },
      { id: 'ws-2', label: 'Workspace 2' },
    ])
    expect(workspaceTargets.value).toHaveLength(2)
    expect(activeWorkspaceId.value).toBe('ws-1')
    expect(sessionEpoch.value).toBeGreaterThan(epoch0)

    const epoch1 = currentSessionEpoch()
    expect(selectWorkspace('ws-2')).toBe(true)
    expect(selectWorkspace('ws-2')).toBe(false) // idempotent
    expect(currentSessionEpoch()).toBe(epoch1 + 1)
    expect(isEpochCurrent(epoch1)).toBe(false)

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
      if (url === '/api/v1/auth/session') {
        return jsonResponse({
          authenticated: true,
          account_id: 'acct-1',
          role: 'worker',
          csrf_token: 'csrf-initial',
        })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    const epochBefore = currentSessionEpoch()
    const dispose = installAuthLifecycleGuards(fetchMock as unknown as typeof fetch)

    try {
      // Simulate another tab signing into a different account
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

      // Verify pagehide wipes transient secrets
      setSingleUserToken('ephemeral-val')
      expect(getSingleUserToken()).toBe('ephemeral-val')
      window.dispatchEvent(new Event('pagehide'))
      expect(getSingleUserToken()).toBeNull()
    } finally {
      dispose()
      wipeTransientSecrets()
    }
  })

  it('refreshes CSRF token in multi_account mode and detects account drift during refresh', async () => {
    let csrfCounter = 1
    let accountId = 'acct-1'
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/health') return jsonResponse({ account_mode: 'Multi_account' })
      if (url === '/api/v1/auth/session') {
        return jsonResponse({
          authenticated: true,
          account_id: accountId,
          role: 'admin',
          csrf_token: `csrf-rev-${csrfCounter++}`,
        })
      }
      throw new Error(`unexpected url: ${url}`)
    })

    await bootstrapAuthSession({ fetchImpl: fetchMock as unknown as typeof fetch })
    expect(getActiveCsrfToken()).toBe('csrf-rev-1')

    const refreshed = await refreshMultiAccountCsrf(fetchMock as unknown as typeof fetch)
    expect(refreshed).toBe('csrf-rev-2')
    expect(getActiveCsrfToken()).toBe('csrf-rev-2')

    // Now account drifts on server
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
      // authSession starts as 'probing' -> MUST NOT fire POST /api/v1/dashboard/nav-event
      expect(fetchSpy).not.toHaveBeenCalled()

      // Multi-account signed out -> still MUST NOT fire
      authSession.value = {
        kind: 'multi_account_signed_out',
        mode: 'multi_account',
        authMethods: { google: true, github: false, dev_token: false },
      }
      routeSig.value = { tab: 'keepers', params: { section: 'keepers' }, postId: null }
      expect(fetchSpy).not.toHaveBeenCalled()

      // Once signed in with CSRF token -> emits with x-masc-csrf-token
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
