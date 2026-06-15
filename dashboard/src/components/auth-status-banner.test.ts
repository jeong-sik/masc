// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { waitFor } from '@testing-library/preact'
import type { DashboardShellAuthSummary } from '../types'

const mockState = vi.hoisted(() => ({
  shellAuthSummary: { value: null as DashboardShellAuthSummary | null },
  refreshShell: vi.fn().mockResolvedValue(undefined),
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn().mockReturnValue('dashboard'),
  dashboardBearerToken: vi.fn().mockReturnValue('stale-token'),
  isRemoteAccess: vi.fn().mockReturnValue(false),
  setStoredToken: vi.fn(),
  resetMcpClientState: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('../store', () => ({
  shellAuthSummary: mockState.shellAuthSummary,
  refreshShell: mockState.refreshShell,
}))

vi.mock('../api/core', () => ({
  clearStoredToken: mockState.clearStoredToken,
  currentDashboardActor: mockState.currentDashboardActor,
  dashboardBearerToken: mockState.dashboardBearerToken,
  isRemoteAccess: mockState.isRemoteAccess,
  setStoredToken: mockState.setStoredToken,
}))

vi.mock('../api/dev-token', () => ({
  devTokenBootstrapStatus: { value: 'idle' },
}))

vi.mock('../api/mcp', () => ({
  resetMcpClientState: mockState.resetMcpClientState,
}))

vi.mock('../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: vi.fn().mockReturnValue({ allowed: false, reason: 'invalid token' }),
  cleanErrorMessage: (value: string | null | undefined): string | null =>
    value ? value.replace(/^[^\w가-힣@]+/u, '').trim() || null : null,
}))

vi.mock('../lib/dashboard-actor', () => ({
  hasDashboardActorQueryParam: vi.fn().mockReturnValue(false),
  readStoredDashboardActorName: vi.fn().mockReturnValue('dashboard'),
  resolveDashboardActorName: vi.fn().mockReturnValue('dashboard'),
  syncDashboardActorName: vi.fn((s: string) => s),
}))

vi.mock('./common/toast', () => ({
  showToast: mockState.showToast,
}))

import {
  RemoteWarningBanner,
  __resetForTests,
  authWarningBannerModel,
} from './auth-status'

const staleTokenSummary = (): DashboardShellAuthSummary => ({
  enabled: true,
  require_token: true,
  token_present: true,
  token_valid: false,
  token_agent: null,
  requested_agent: 'dashboard',
  effective_agent: null,
  effective_role: null,
  default_role: 'reader',
  auth_error_code: 'invalid_token',
  auth_error_detail: 'Invalid token: Token mismatch',
  can_keeper_msg: false,
  keeper_msg_error: 'Invalid token: Token mismatch',
})

describe('RemoteWarningBanner auth-error visibility', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mockState.shellAuthSummary.value = null
    mockState.refreshShell.mockClear()
    mockState.clearStoredToken.mockClear()
    mockState.resetMcpClientState.mockClear()
    mockState.showToast.mockClear()
    mockState.isRemoteAccess.mockReturnValue(false)
    __resetForTests()
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    __resetForTests()
  })

  it('models stale bearer token warnings independently of remote access', () => {
    expect(authWarningBannerModel(staleTokenSummary(), false)).toMatchObject({
      action: 'auth_error',
      canClearToken: true,
    })
  })

  it('renders stale bearer token remediation on loopback dashboards', () => {
    mockState.shellAuthSummary.value = staleTokenSummary()
    mockState.isRemoteAccess.mockReturnValue(false)

    render(html`<${RemoteWarningBanner} />`, container)

    const alert = container.querySelector('[role="alert"]')
    expect(alert?.textContent).toContain('Stored Bearer token is not verified')
    expect(alert?.textContent).toContain('Clear token')
  })

  it('clears the stored token from the warning banner', async () => {
    mockState.shellAuthSummary.value = staleTokenSummary()
    render(html`<${RemoteWarningBanner} />`, container)

    const clearButton = container.querySelector(
      'button[aria-label="Clear stored bearer token"]',
    ) as HTMLButtonElement
    expect(clearButton).not.toBeNull()
    clearButton.click()

    await waitFor(() => {
      expect(mockState.clearStoredToken).toHaveBeenCalledTimes(1)
      expect(mockState.resetMcpClientState).toHaveBeenCalledTimes(1)
      expect(mockState.refreshShell).toHaveBeenCalledTimes(1)
    })
  })

  it('does not render after token verification succeeds', () => {
    mockState.shellAuthSummary.value = {
      ...staleTokenSummary(),
      token_valid: true,
      auth_error_code: null,
      auth_error_detail: null,
    }

    render(html`<${RemoteWarningBanner} />`, container)

    expect(container.querySelector('[role="alert"]')).toBeNull()
  })
})
