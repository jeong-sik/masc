import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  fetchPauseStatus,
  pauseRoom,
  resumeRoom,
  flowState,
  flowLoading,
  shellAuthSummary,
  requestConfirm,
  authAccess,
} = vi.hoisted(() => ({
  fetchPauseStatus: vi.fn().mockResolvedValue(undefined),
  pauseRoom: vi.fn().mockResolvedValue(undefined),
  resumeRoom: vi.fn().mockResolvedValue(undefined),
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' },
  flowLoading: { value: false },
  shellAuthSummary: { value: null },
  requestConfirm: vi.fn().mockResolvedValue(true),
  authAccess: { allowed: true, reason: null as string | null },
}))

vi.mock('./flow-control/flow-control-state', () => ({
  fetchPauseStatus,
  pauseRoom,
  resumeRoom,
  flowState,
  flowLoading,
}))

vi.mock('../store', () => ({ shellAuthSummary }))

vi.mock('../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: () => authAccess,
}))

vi.mock('./common/confirm-dialog', () => ({ requestConfirm }))

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
    requestConfirm.mockResolvedValue(true)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('renders an Emergency Stop button when running with worker access', async () => {
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Emergency Stop')
    expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBeTruthy()
  })

  it('pauses the namespace after the confirmation is accepted', async () => {
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    const btn = container.querySelector('[data-testid="emergency-stop-control"]') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(requestConfirm).toHaveBeenCalledTimes(1)
    expect(pauseRoom).toHaveBeenCalledTimes(1)
  })

  it('does not pause when the confirmation is declined', async () => {
    requestConfirm.mockResolvedValue(false)
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    const btn = container.querySelector('[data-testid="emergency-stop-control"]') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(requestConfirm).toHaveBeenCalledTimes(1)
    expect(pauseRoom).not.toHaveBeenCalled()
  })

  it('hides the Emergency Stop button when worker access is denied', async () => {
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
  })

  it('resumes the namespace when Resume is clicked', async () => {
    flowState.value = 'paused'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    // Resume is the only button rendered in the paused state.
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(resumeRoom).toHaveBeenCalledTimes(1)
  })

  it('renders nothing while the flow state is unknown', async () => {
    flowState.value = 'unknown'
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    expect(container.textContent).toBe('')
    expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBeNull()
  })
})
