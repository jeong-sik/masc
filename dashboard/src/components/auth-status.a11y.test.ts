// @vitest-environment happy-dom
//
// jest-axe coverage for AuthStatus popover (RFC 0002 Iter 2). Locks the
// aria-expanded / aria-haspopup / aria-controls / aria-labelledby wiring
// + role="dialog" + sr-only label so future migrations land as
// zero-regression. axe verifies the trigger↔panel id wiring is sound.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'

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

describe('AuthStatus a11y (Iter 2)', () => {
  let container: HTMLElement

  beforeEach(() => {
    __resetForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    __resetForTests()
  })

  it('trigger collapsed passes axe', async () => {
    render(html`<${AuthStatus} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('popover open passes axe (aria-expanded + aria-controls + role=dialog wiring)', async () => {
    render(html`<${AuthStatus} />`, container)
    const trigger = container.querySelector('button[aria-haspopup]') as HTMLButtonElement
    trigger.click()
    await flushUi()
    expect(container.querySelector('[role="dialog"]')).not.toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })
})
