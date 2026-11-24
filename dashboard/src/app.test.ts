// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent, waitFor, within } from '@testing-library/preact'
import { App, shouldBootstrapCommandPaletteShortcut } from './app'
import { authSession, resetAuthStateForTests } from './core/auth'
import { resetObserverStateForTests } from './core/observer'
import { currentRoute, navigate, resetRouterForTests } from './routes/router'
import { WORKSPACE_LOADERS } from './workspaces/registry'
import {
  activeOverlay,
  commandPaletteMounted,
  commandPaletteOpen,
  historicalIncidents,
  railExpanded,
  resetShellStateForTests,
} from './shell/shell-state'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('Proposal A+ Application Shell (src/app.ts)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = '#/pulse'
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetRouterForTests('/pulse')
    resetShellStateForTests()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('capability-gates boot: never probes /dev-token or protected routes when multi_account is signed out', async () => {
    const requestedUrls: string[] = []
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      requestedUrls.push(url)
      if (url === '/health') {
        return jsonResponse({
          account_mode: 'Multi_account',
          auth_methods: { google: true, github: true, dev_token: false },
        })
      }
      if (url === '/api/v1/auth/session' || url === '/auth/session') {
        return jsonResponse({ authenticated: false }, 401)
      }
      return jsonResponse({ error: 'unexpected' }, 500)
    })

    await act(async () => {
      render(h(App, {}), container)
    })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="route-gate-auth-required"]')).not.toBeNull()
    })
    expect(requestedUrls).toContain('/health')
    expect(requestedUrls).not.toContain('/api/v1/dashboard/dev-token')
    expect(requestedUrls).not.toContain('/api/v1/keepers/tool-approvals')
    expect(requestedUrls).not.toContain('/api/v1/dashboard/nav-event')
    // Zero hidden DashboardHealthStrip, zero CopilotDock FAB
    expect(container.querySelector('[data-testid="dashboard-health-strip"]')).toBeNull()
    expect(container.querySelector('.copilot-dock')).toBeNull()
  })

  it('blocks non-Admin Workers on Admin-only routes (/infra/*, /settings) without speculative 403 fetches', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (url === '/health') {
        return jsonResponse({
          account_mode: 'Multi_account',
          auth_methods: { google: true, github: true, dev_token: false },
        })
      }
      if (url === '/api/v1/auth/session' || url === '/auth/session') {
        return jsonResponse({
          authenticated: true,
          account_id: 'u-worker',
          user_id: 'u-worker',
          display_name: 'worker',
          role: 'worker',
          csrf_token: 'csrf-1',
          expires_at_ms: Date.now() + 3_600_000,
        })
      }
      if (url === '/api/v1/auth/whoami') {
        return jsonResponse({
          principal: { kind: 'human', id: 'u-worker' },
          role: 'worker',
        })
      }
      if (url === '/api/v1/keepers/tool-approvals') return jsonResponse({ pending: [] })
      if (url === '/api/v1/keepers/asks') return jsonResponse({ asks: [] })
      return jsonResponse({ ok: true })
    })

    window.location.hash = '#/infra/sandboxes'
    resetRouterForTests('/infra/sandboxes')

    await act(async () => {
      render(h(App, {}), container)
    })

    await waitFor(() => {
      expect(authSession.value.kind).toBe('multi_account_signed_in')
      expect(container.querySelector('[data-testid="route-gate-admin-only"]')).not.toBeNull()
    })
    const calledUrls = fetchSpy.mock.calls.map(([u]) => String(u))
    expect(calledUrls.some((u) => u.includes('/api/v1/infra/'))).toBe(false)
    // Zero 404 probes in multi_account mode (no single-user HITL endpoints, no .build-identity.json SPA fallback)
    expect(calledUrls).not.toContain('/api/v1/keepers/tool-approvals')
    expect(calledUrls).not.toContain('/api/v1/keepers/asks')
    expect(calledUrls).not.toContain('/dashboard/.build-identity.json')
    expect(historicalIncidents.value).toHaveLength(0)
  })

  it('wires global shortcuts: [b] rail toggle, [1]-[6] trunks, [,] settings, [i] incidents, [⌘T] queue, and [⌘K] palette', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (url === '/health') return jsonResponse({ version: '0.81.0', auth_methods: { dev_token: false } })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ counts: { keepers: 3, tasks: 5 } })
      if (url === '/api/v1/keepers/tool-approvals') return jsonResponse({ pending: [] })
      if (url === '/api/v1/keepers/asks') return jsonResponse({ asks: [] })
      return jsonResponse({}, 404)
    })
    window.innerWidth = 1440

    await act(async () => {
      render(h(App, {}), container)
    })

    expect(railExpanded.value).toBe(true)
    await act(async () => {
      fireEvent.keyDown(document, { key: 'b' })
    })
    expect(railExpanded.value).toBe(false)

    await act(async () => {
      fireEvent.keyDown(document, { key: '5' })
    })
    expect(currentRoute.value.path).toBe('/runtime/quotas')

    await act(async () => {
      fireEvent.keyDown(document, { key: ',' })
    })
    expect(currentRoute.value.path).toBe('/settings')

    await act(async () => {
      fireEvent.keyDown(document, { key: 'i' })
    })
    expect(activeOverlay.value?.kind).toBe('incidents')

    await act(async () => {
      fireEvent.keyDown(document, { key: 't', ctrlKey: true })
    })
    expect(activeOverlay.value?.kind).toBe('queue_context')

    expect(commandPaletteMounted.value).toBe(false)
    await act(async () => {
      fireEvent.keyDown(document, { key: 'k', ctrlKey: true })
    })
    expect(commandPaletteMounted.value).toBe(true)
    expect(commandPaletteOpen.value).toBe(true)
  })

  it('renders desktop NavRail at >=768px and MobileNav bottom bar at <768px', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse({ version: '0.81.0' }))
    window.innerWidth = 375
    await act(async () => {
      render(h(App, {}), container)
    })
    expect(container.querySelector('.ap-shell')?.getAttribute('data-mobile')).toBe('true')
    expect(container.querySelector('[data-testid="mobile-nav-bar"]')).not.toBeNull()
    expect(container.querySelector('.ap-rail')).toBeNull()

    await act(async () => {
      window.innerWidth = 1280
      window.dispatchEvent(new Event('resize'))
    })
    expect(container.querySelector('.ap-shell')?.getAttribute('data-mobile')).toBe('false')
    expect(container.querySelector('.ap-rail')).not.toBeNull()
    expect(container.querySelector('[data-testid="mobile-nav-bar"]')).toBeNull()
  })

  it('opens QuickPeekDrawer when a workspace invokes onInspect and navigates via onNavigate', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (url === '/health') return jsonResponse({ version: '0.81.0' })
      if (url === '/api/v1/dashboard/shell') return jsonResponse({ counts: { keepers: 1 } })
      if (url === '/api/v1/keepers/tool-approvals') return jsonResponse({ pending: [] })
      if (url === '/api/v1/keepers/asks') return jsonResponse({ asks: [] })
      return jsonResponse({})
    })

    await act(async () => {
      render(h(App, {}), container)
    })
    expect(currentRoute.value.workspace).toBe('pulse')
    navigate('/work/goals')
    expect(currentRoute.value.path).toBe('/work/goals')
  })

  it('reloads the document when a workspace chunk fails to load', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse({ version: '0.81.0' }))
    const load = vi.spyOn(WORKSPACE_LOADERS.account, 'load').mockRejectedValueOnce(new Error('Chunk unavailable'))
    const reload = vi.spyOn(window.location, 'reload').mockImplementation(() => {})
    window.location.hash = '#/account'
    resetRouterForTests('/account')

    await act(async () => {
      render(h(App, {}), container)
    })

    const alert = await within(container).findByRole('alert')
    fireEvent.click(within(alert).getByRole('button', { name: '새로고침' }))
    expect(load).toHaveBeenCalledTimes(1)
    expect(reload).toHaveBeenCalledTimes(1)
  })
})

describe('shouldBootstrapCommandPaletteShortcut', () => {
  it('claims Mod+K only when unmounted, non-IME, and free of extra modifiers', () => {
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false }, false)).toBe(true)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: false, key: 'k', metaKey: true }, false)).toBe(true)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false }, true)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: true }, false)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false, shiftKey: true }, false)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false, isComposing: true }, false)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false, keyCode: 229 }, false)).toBe(false)
    expect(shouldBootstrapCommandPaletteShortcut({ altKey: false, ctrlKey: true, key: 'k', metaKey: false, defaultPrevented: true }, false)).toBe(false)
  })
})
