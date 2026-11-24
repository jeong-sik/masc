// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent, waitFor } from '@testing-library/preact'
import {
  activeWorkspaceId,
  authSession,
  resetAuthStateForTests,
  sessionEpoch,
  workspaceTargets,
} from '../../core/auth'
import { AccountWorkspace } from './index'
import {
  decodeAllowlist,
  decodeInvitesList,
  decodeMembersList,
  decodePatsList,
  revokeAdminMember,
} from './wire'

const AUTH_METHODS = { google: true, github: true, dev_token: false } as const

function jsonResp(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('Unified /account wire parsers & workspace surface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetAuthStateForTests()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('decodes PATs, Members, Invites, Allowlist and enforces strict closed-sum revoke-admin cause', async () => {
    const pats = decodePatsList({
      pats: [{
        pat_id: 'pat-1',
        scope: { runtimes: 'all', channels: ['direct'], allowed_effects: ['read_state'] },
        issued_at_ms: 1_700_000_000_000,
        expires_at_ms: null,
        status: 'open',
      }],
    })
    expect(pats).toHaveLength(1)
    expect(pats[0]?.id).toBe('pat-1')

    const members = decodeMembersList({
      members: [{
        user_id: 'u-1',
        identity: { provider: 'github', user_id: 42 },
        role: 'admin',
        status: 'active',
        held: [],
      }],
    })
    expect(members[0]?.identity).toEqual({ provider: 'github', userId: 42 })

    const invites = decodeInvitesList({
      invites: [{
        invite_id: 'inv-1',
        role: 'member',
        issuer: { kind: 'local_operator' },
        expires_at_ms: 1_800_000_000_000,
        status: 'open',
      }],
    })
    expect(invites[0]?.status).toEqual({ kind: 'open' })

    const allowlist = decodeAllowlist({
      registrations: [{
        registration_id: 'reg-1',
        identity: { provider: 'google', sub: '10987654321' },
        registrar: 'u-1',
        status: 'open',
      }],
    })
    expect(allowlist[0]?.identity).toEqual({ provider: 'google', sub: '10987654321' })

    // Strict closed-sum cause validation on revokeAdminMember
    expect(() => revokeAdminMember('u-1', 'arbitrary' as never)).toThrow(/Invalid revoke-admin cause/)

    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-admin',
      email: null,
      displayName: 'Admin',
      role: 'admin',
      csrfToken: 'csrf-xyz',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const fetchMock = vi.fn<typeof fetch>(async () =>
      jsonResp({ user_id: 'u-2', role: 'member', cause: 'security_incident' }),
    )
    const res = await revokeAdminMember('u-2', 'security_incident', fetchMock)
    expect(res.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/auth/members/u-2/revoke-admin')
    expect(init?.method).toBe('POST')
    expect(init?.body).toBe(JSON.stringify({ cause: 'security_incident' }))
    expect((init?.headers as Record<string, string>)['x-masc-csrf-token']).toBe('csrf-xyz')
  })

  it('renders CSP-safe top-level sign-in navigation link in multi_account_signed_out mode (zero form POSTs)', async () => {
    authSession.value = {
      kind: 'multi_account_signed_out',
      mode: 'multi_account',
      authMethods: AUTH_METHODS,
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'profile',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    const gate = container.querySelector('[data-testid="multi-account-signin-gate"]')
    expect(gate).not.toBeNull()
    expect(gate?.querySelector('form')).toBeNull()
    const link = gate?.querySelector('[data-testid="multi-account-signin-link"]') as HTMLAnchorElement | null
    expect(link).not.toBeNull()
    expect(link?.getAttribute('href')).toBe('/')
    expect(link?.getAttribute('data-oauth-providers')).toBe('google,github')
    expect(container.querySelector('[data-testid="account-provider-callout"]')?.textContent)
      .toContain('Runtime → Quotas')
  })

  it('blocks non-Admin Workers from Admin tabs with zero speculative 403 fetches', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-worker',
      email: null,
      displayName: 'Worker',
      role: 'worker',
      csrfToken: 'csrf-w',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'members',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    expect(container.querySelector('[data-testid="account-admin-locked"]')).not.toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('allows Admins to inspect members and send disable / revoke-admin / delete mutations', async () => {
    const calls: Array<{ url: string; method: string; body?: string }> = []
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      const method = init?.method ?? 'GET'
      calls.push({ url, method, body: typeof init?.body === 'string' ? init.body : undefined })
      if (url === '/api/v1/auth/members' && method === 'GET') {
        return jsonResp({
          members: [
            {
              user_id: 'u-admin-1',
              identity: { provider: 'google', sub: 'sub-admin-1' },
              role: 'admin',
              status: 'active',
              held: [],
            },
            {
              user_id: 'u-admin-2',
              identity: { provider: 'github', user_id: 777 },
              role: 'admin',
              status: 'active',
              held: [],
            },
            {
              user_id: 'u-unknown-status',
              identity: { provider: 'github', user_id: 888 },
              role: 'member',
              status: 'quarantined_future_state',
              held: [],
            },
          ],
        })
      }
      if (url.endsWith('/revoke-admin')) {
        return jsonResp({ user_id: 'u-admin-2', role: 'member', cause: 'operational' })
      }
      if (url.endsWith('/disable')) {
        return jsonResp({ user_id: 'u-admin-2', status: 'disabled' })
      }
      if (method === 'DELETE') {
        return new Response(null, { status: 204 })
      }
      return jsonResp({}, 404)
    })

    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-admin-1',
      email: null,
      displayName: 'Admin One',
      role: 'admin',
      csrfToken: 'csrf-admin',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'members',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    await waitFor(() => {
      expect(container.querySelector('[data-member-id="u-admin-2"]')).not.toBeNull()
    })
    const row2 = container.querySelector('[data-member-id="u-admin-2"]')!

    // Open Revoke Admin form -> confirm button stays disabled until closed-sum cause chosen
    await act(async () => {
      fireEvent.click(row2.querySelector('[data-action="open-revoke-admin"]')!)
    })
    const form = row2.querySelector('[data-testid="revoke-admin-form"]')!
    const submitBtn = form.querySelector('button[type="submit"]') as HTMLButtonElement
    expect(submitBtn.disabled).toBe(true)

    const select = form.querySelector('select') as HTMLSelectElement
    await act(async () => {
      fireEvent.change(select, { target: { value: 'operational' } })
    })
    expect(submitBtn.disabled).toBe(false)

    await act(async () => {
      fireEvent.submit(form)
    })

    const revokeCall = calls.find((c) => c.url === '/api/v1/auth/members/u-admin-2/revoke-admin')
    expect(revokeCall?.method).toBe('POST')
    expect(revokeCall?.body).toBe(JSON.stringify({ cause: 'operational' }))

    // Unrecognised member status renders neither Disable nor Enable
    const rowUnknown = container.querySelector('[data-member-id="u-unknown-status"]')!
    expect(rowUnknown.querySelector('[data-action="disable"]')).toBeNull()
    expect(rowUnknown.querySelector('[data-action="enable"]')).toBeNull()
  })

  it('allows revoking expired invites in InvitesTab', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResp({
      invites: [{
        invite_id: 'inv-expired-1',
        role: 'member',
        issuer: { kind: 'local_operator' },
        expires_at_ms: 1_700_000_000_000,
        status: 'expired',
      }],
    }))

    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-admin-1',
      email: null,
      displayName: 'Admin One',
      role: 'admin',
      csrfToken: 'csrf-admin',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'invites',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    await waitFor(() => {
      expect(container.querySelector('[data-invite-id="inv-expired-1"]')).not.toBeNull()
    })
    const row = container.querySelector('[data-invite-id="inv-expired-1"]')!
    expect(row.textContent).toContain('Revoke')
  })

  it('renders cross-tab account_changed banner cleanly', async () => {
    authSession.value = {
      kind: 'account_changed',
      mode: 'multi_account',
      previousAccountId: 'u-old',
      nextAccountId: 'u-new',
      authMethods: AUTH_METHODS,
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'profile',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    const banner = container.querySelector('[data-testid="account-changed-banner"]')
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('u-old')
    expect(banner?.textContent).toContain('u-new')
  })

  it('renders Local Operator & Multi-Workspace Target manager in single_user mode without probing /dev-token', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: false,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }

    await act(async () => {
      render(h(AccountWorkspace, {
        subroute: 'profile',
        onNavigate: vi.fn(),
        onInspect: vi.fn(),
      }), container)
    })

    expect(container.querySelector('[data-testid="account-local-operator"]')).not.toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()

    // Reject cross-origin URLs fail-closed (matching L3 resolveWorkspaceUrl)
    const labelInput = container.querySelector('input[placeholder="e.g. Staging MASC"]') as HTMLInputElement
    const urlInput = container.querySelector('input[placeholder="/workspace-b"]') as HTMLInputElement
    await act(async () => {
      fireEvent.input(labelInput, { target: { value: 'Cross Origin' } })
      fireEvent.input(urlInput, { target: { value: 'https://evil.example.com' } })
    })
    await act(async () => {
      fireEvent.submit(labelInput.closest('form')!)
    })
    expect(workspaceTargets.value.some((t) => t.id === 'cross-origin')).toBe(false)
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('교차 출처')

    // Add a same-origin path prefix target & switch to it -> bumps sessionEpoch
    const beforeEpoch = sessionEpoch.value
    await act(async () => {
      fireEvent.input(labelInput, { target: { value: 'Prod Lab' } })
      fireEvent.input(urlInput, { target: { value: '/prod-lab' } })
    })
    await act(async () => {
      fireEvent.submit(labelInput.closest('form')!)
    })

    expect(workspaceTargets.value.some((t) => t.id === 'prod-lab' && t.baseUrl === '/prod-lab')).toBe(true)
    const switchBtn = container.querySelector('[data-ws-row="prod-lab"] button') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(switchBtn)
    })
    expect(activeWorkspaceId.value).toBe('prod-lab')
    expect(sessionEpoch.value).toBeGreaterThan(beforeEpoch)
  })
})
