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

vi.mock('../store', () => ({
  shellAuthSummary: { value: null },
  refreshShell: vi.fn().mockResolvedValue(undefined),
}))
vi.mock('../api/core', () => ({
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn().mockReturnValue('test'),
  isRemoteAccess: vi.fn().mockReturnValue(false),
  setStoredToken: vi.fn(),
}))
vi.mock('../api/mcp', () => ({ resetMcpClientState: vi.fn() }))
vi.mock('../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: vi.fn().mockReturnValue({ allowed: true, reason: null }),
}))
vi.mock('../lib/dashboard-actor', () => ({
  hasDashboardActorQueryParam: vi.fn().mockReturnValue(false),
  readStoredDashboardActorName: vi.fn().mockReturnValue('test'),
  resolveDashboardActorName: vi.fn().mockReturnValue('test'),
  syncDashboardActorName: vi.fn((s: string) => s),
}))
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { AuthStatus, __resetForTests } from './auth-status'

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
    expect(container.querySelector('[role="dialog"]')).not.toBeNull()

    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await flushUi()

    expect(container.querySelector('[role="dialog"]')).toBeNull()
    expect(document.activeElement).toBe(trigger)
  })
})
