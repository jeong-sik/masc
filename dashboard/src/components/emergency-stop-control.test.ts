import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
  flowState,
  flowLoading,
  shellAuthSummary,
  authAccess,
} = vi.hoisted(() => ({
  fetchPauseStatus: vi.fn().mockResolvedValue(undefined),
  pauseWorkspace: vi.fn().mockResolvedValue(undefined),
  resumeWorkspace: vi.fn().mockResolvedValue(undefined),
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' },
  flowLoading: { value: false },
  shellAuthSummary: { value: null },
  authAccess: { allowed: true, reason: null as string | null },
}))

vi.mock('./flow-control/flow-control-state', () => ({
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
  flowState,
  flowLoading,
}))

vi.mock('../store', () => ({ shellAuthSummary }))

vi.mock('../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: () => authAccess,
}))

import { EmergencyStopControl } from './emergency-stop-control'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

describe('EmergencyStopControl', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    flowState.value = 'running'
    flowLoading.value = false
    shellAuthSummary.value = null
    authAccess.allowed = true
    authAccess.reason = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('renders an Emergency Stop button when running with admin access', async () => {
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Emergency Stop')
    expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBeTruthy()
    expect(container.querySelector('.emergency-stop-control')).toBeTruthy()
  })

  it('delegates the click to the operator-confirm-gated pause action', async () => {
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    const btn = container.querySelector('[data-testid="emergency-stop-control"]') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(pauseWorkspace).toHaveBeenCalledTimes(1)
  })

  it('hides the Emergency Stop button when admin access is denied', async () => {
    authAccess.allowed = false
    authAccess.reason = 'viewer role cannot pause'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('Emergency Stop')
  })

  it('shows a Paused badge and a Resume button when paused', async () => {
    flowState.value = 'paused'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Paused')
    expect(container.textContent).toContain('Resume')
    expect(container.querySelector('.emergency-stop-control')).toBeTruthy()
  })

  it('resumes the namespace when Resume is clicked', async () => {
    flowState.value = 'paused'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    // Resume is the only button rendered in the paused state.
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(resumeWorkspace).toHaveBeenCalledTimes(1)
  })

  it('renders nothing while the flow state is unknown', async () => {
    flowState.value = 'unknown'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).toBe('')
    expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBeNull()
  })
})
