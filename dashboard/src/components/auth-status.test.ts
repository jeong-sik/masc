// @vitest-environment happy-dom
//
// Behavior tests for AuthStatus's popover (RFC 0002 Iter 2 — useFocusScope
// migration). Locks the user-observable contract: trigger toggles open/
// closed, data-state surfaces the state, focus moves into the panel on
// open and restores on close, ESC closes the popover.
//
// These tests run on the migrated (post-Cycle 1) AuthStatus and verify
// that the inline focus management replacement (useFocusScope) preserves
// the popover lifecycle while introducing focus trap + ESC capabilities.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { waitFor } from '@testing-library/preact'

vi.mock('../store', () => ({
  shellAuthSummary: { value: null },
  refreshShell: vi.fn().mockResolvedValue(undefined),
}))
vi.mock('../api/core', () => ({
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn().mockReturnValue('test'),
  dashboardBearerToken: vi.fn().mockReturnValue(null),
  isRemoteAccess: vi.fn().mockReturnValue(false),
  setStoredToken: vi.fn(),
}))
vi.mock('../api/mcp', () => ({ resetMcpClientState: vi.fn() }))
vi.mock('../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: vi.fn().mockReturnValue({ allowed: true, reason: null }),
  cleanErrorMessage: (value: string | null | undefined): string | null =>
    value ? value.replace(/^[^\w가-힣@]+/u, '').trim() || null : null,
  compactWhitespace: (value: string): string => value.replace(/\s+/g, ' ').trim(),
}))
vi.mock('../lib/dashboard-actor', () => ({
  hasDashboardActorQueryParam: vi.fn().mockReturnValue(false),
  readStoredDashboardActorName: vi.fn().mockReturnValue('test'),
  resolveDashboardActorName: vi.fn().mockReturnValue('test'),
  syncDashboardActorName: vi.fn((s: string) => s),
}))
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { AuthStatus, __resetForTests } from './auth-status'
import { shellAuthSummary } from '../store'

const flushUi = (): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, 30))

describe('AuthStatus popover behavior (Iter 2)', () => {
  let container: HTMLElement
  let outsideButton: HTMLButtonElement

  beforeEach(() => {
    document.body.innerHTML = ''
    __resetForTests()

    outsideButton = document.createElement('button')
    outsideButton.id = 'outside'
    outsideButton.textContent = 'outside'
    document.body.appendChild(outsideButton)

    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.innerHTML = ''
    __resetForTests()
  })

  it('renders the trigger collapsed (popover closed) by default', () => {
    render(html`<${AuthStatus} />`, container)
    const trigger = container.querySelector('button[aria-haspopup]')
    expect(trigger).not.toBeNull()
    expect(trigger?.getAttribute('aria-expanded')).toBe('false')
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('clicking the trigger opens the popover with data-state="open" and aria wiring', async () => {
    render(html`<${AuthStatus} />`, container)
    const trigger = container.querySelector('button[aria-haspopup]') as HTMLButtonElement
    trigger.click()
    await flushUi()

    const panel = container.querySelector('[role="dialog"]')
    expect(panel).not.toBeNull()
    expect(panel?.getAttribute('data-state')).toBe('open')

    const labelledBy = panel?.getAttribute('aria-labelledby') ?? ''
    expect(labelledBy).not.toBe('')
    expect(panel?.querySelector(`#${CSS.escape(labelledBy)}`)).not.toBeNull()

    const ariaControls = trigger.getAttribute('aria-controls') ?? ''
    expect(ariaControls).toBe(panel?.id ?? '__missing__')
    expect(trigger.getAttribute('aria-expanded')).toBe('true')
  })

  it('opening the popover moves focus into the panel (focus trap activate)', async () => {
    outsideButton.focus()
    expect(document.activeElement?.id).toBe('outside')

    render(html`<${AuthStatus} />`, container)
    const trigger = container.querySelector('button[aria-haspopup]') as HTMLButtonElement
    trigger.click()
    await flushUi()

    const panel = container.querySelector('[role="dialog"]')
    expect(panel).not.toBeNull()
    // First tabbable inside the panel is whatever Tabbable filter picked
    // — the precise element depends on actorOverrideLocked branch — but
    // the focus must have left `outside` and landed inside the panel.
    expect(document.activeElement).not.toBe(outsideButton)
    expect(panel?.contains(document.activeElement)).toBe(true)
  })

  it('Escape key closes the popover and restores focus to the trigger', async () => {
    render(html`<${AuthStatus} />`, container)
    const trigger = container.querySelector('button[aria-haspopup]') as HTMLButtonElement
    trigger.focus()
    expect(document.activeElement).toBe(trigger)

    trigger.click()
    await flushUi()
    const panel = container.querySelector('[role="dialog"]')
    expect(panel).not.toBeNull()
    await waitFor(() => {
      expect(panel?.contains(document.activeElement)).toBe(true)
    })

    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )

    await waitFor(() => {
      expect(container.querySelector('[role="dialog"]')).toBeNull()
    })
    expect(document.activeElement).toBe(trigger)
  })
})

// The badge is the first thing an operator reads when a panel looks empty, so
// it has to separate "you have not signed in" from "the system rejected you".
// A red "Auth error" on a dashboard whose data is loading fine sends people
// looking for an outage that is not there — observed on a live fleet where
// every HTTP surface returned 200 and the badge still read Auth error.
describe('AuthStatus badge distinguishes absent credentials from rejected ones', () => {
  let container: HTMLElement

  beforeEach(() => {
    document.body.innerHTML = ''
    __resetForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.innerHTML = ''
    ;(shellAuthSummary as { value: unknown }).value = null
    __resetForTests()
  })

  function renderWith(summary: Record<string, unknown>): string {
    ;(shellAuthSummary as { value: unknown }).value = summary
    render(html`<${AuthStatus} />`, container)
    return container.textContent ?? ''
  }

  it('reads "Login required" when no token was ever sent', () => {
    const text = renderWith({
      enabled: true,
      require_token: true,
      token_present: false,
      token_valid: false,
      auth_error_code: 'missing_token',
    })
    expect(text).toContain('Login required')
    expect(text).not.toContain('Auth error')
  })

  it('reads "Auth error" when a token was sent and rejected', () => {
    const text = renderWith({
      enabled: true,
      require_token: true,
      token_present: true,
      token_valid: false,
      auth_error_code: 'invalid_token',
    })
    expect(text).toContain('Auth error')
    expect(text).not.toContain('Login required')
  })

  it('treats an actor mismatch as a rejection, not a missing credential', () => {
    const text = renderWith({
      enabled: true,
      require_token: true,
      token_present: true,
      token_valid: false,
      auth_error_code: 'actor_mismatch',
    })
    expect(text).toContain('Auth error')
  })

  it('reads verified when the token checks out', () => {
    const text = renderWith({
      enabled: true,
      require_token: true,
      token_present: true,
      token_valid: true,
      effective_agent: 'dashboard',
      effective_role: 'worker',
    })
    expect(text).toContain('Verified')
    expect(text).not.toContain('Auth error')
    expect(text).not.toContain('Login required')
  })
})
