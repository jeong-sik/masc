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
} = vi.hoisted(() => ({
  fetchPauseStatus: vi.fn().mockResolvedValue(undefined),
  pauseWorkspace: vi.fn().mockResolvedValue(undefined),
  resumeWorkspace: vi.fn().mockResolvedValue(undefined),
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' },
  flowLoading: { value: false },
  shellAuthSummary: { value: null as { effective_role: 'worker' | 'admin' } | null },
}))

vi.mock('./flow-control/flow-control-state', () => ({
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
  flowState,
  flowLoading,
}))

vi.mock('../store', () => ({ shellAuthSummary }))

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
    shellAuthSummary.value = { effective_role: 'admin' }
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

  it('delegates Emergency Stop to the shared namespace confirmation flow', async () => {
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()
    const btn = container.querySelector('[data-testid="emergency-stop-control"]') as HTMLButtonElement
    btn.click()
    await flushUi()
    expect(pauseWorkspace).toHaveBeenCalledTimes(1)
  })

  it('hides the Emergency Stop button for a worker', async () => {
    shellAuthSummary.value = { effective_role: 'worker' }
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

  it('keeps the paused badge without a worker Resume control', async () => {
    flowState.value = 'paused'
    shellAuthSummary.value = { effective_role: 'worker' }
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()
    expect(container.textContent).toContain('Paused')
    expect(container.querySelector('button')).toBeNull()
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
