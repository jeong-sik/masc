import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { getByRole, queryByRole } from '@testing-library/preact'
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
    const btn = getByRole(container, 'button', { name: 'Emergency Stop' })
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

    const btn = getByRole(container, 'button', { name: 'Resume' })
    btn.click()
    await flushUi()

    expect(resumeWorkspace).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['unknown', 'Pause unavailable'],
    ['initializing', 'Checking pause'],
  ] as const)('keeps %s visible and blocks actions until state is known', async (state, label) => {
    flowState.value = state
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()

    const button = getByRole(container, 'button', { name: label }) as HTMLButtonElement
    expect(button.disabled).toBe(true)
    button.click()
    expect(pauseWorkspace).not.toHaveBeenCalled()
    expect(resumeWorkspace).not.toHaveBeenCalled()
    expect(queryByRole(container, 'button', { name: 'Emergency Stop' })).toBeNull()
    expect(queryByRole(container, 'button', { name: 'Resume' })).toBeNull()
  })

  it('keeps the control mounted through authority withdrawal and recovery', async () => {
    flowState.value = 'initializing'
    await act(async () => { render(html`<${EmergencyStopControl} />`, container) })
    const control = container.querySelector('[data-testid="emergency-stop-control"]')
    expect(control).toBeTruthy()
    for (const state of ['running', 'unknown', 'paused'] as const) {
      flowState.value = state
      await act(async () => { render(html`<${EmergencyStopControl} />`, container) })
      expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBe(control)
    }
    getByRole(container, 'button', { name: 'Resume' }).click()
    expect(resumeWorkspace).toHaveBeenCalledTimes(1)
    expect(pauseWorkspace).not.toHaveBeenCalled()
  })

  it.each(['unknown', 'initializing'] as const)('does not expose %s operator controls to a worker', async state => {
    flowState.value = state
    shellAuthSummary.value = { effective_role: 'worker' }
    render(html`<${EmergencyStopControl} />`, container)
    await flushUi()
    expect(queryByRole(container, 'button')).toBeNull()
    expect(container.querySelector('[data-testid="emergency-stop-control"]')).toBeNull()
  })
})
