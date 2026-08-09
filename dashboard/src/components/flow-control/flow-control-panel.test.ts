import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type MockOperatorSnapshot = {
  inference_inflight?: {
    boundary_owner: 'agent_core_runtime'
    active: number
  } | null
} | null

const {
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
  runGarbageCollection,
  flowState,
  flowLoading,
  maintenanceResult,
  maintenanceLoading,
  shellAuthSummary,
  operatorSnapshot,
  dashboardAuthAccess,
} = vi.hoisted(() => ({
  fetchPauseStatus: vi.fn().mockResolvedValue(undefined),
  pauseWorkspace: vi.fn().mockResolvedValue(undefined),
  resumeWorkspace: vi.fn().mockResolvedValue(undefined),
  runGarbageCollection: vi.fn().mockResolvedValue(undefined),
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' },
  flowLoading: { value: false },
  maintenanceResult: { value: null as string | null },
  maintenanceLoading: { value: false },
  shellAuthSummary: { value: null },
  operatorSnapshot: { value: null as MockOperatorSnapshot },
  dashboardAuthAccess: vi.fn(),
}))

vi.mock('./flow-control-state', () => ({
  fetchPauseStatus,
  flowLoading,
  flowState,
  maintenanceLoading,
  maintenanceResult,
  pauseWorkspace,
  resumeWorkspace,
  runGarbageCollection,
}))

vi.mock('../../store', () => ({
  shellAuthSummary,
}))

vi.mock('../../operator-store', () => ({
  operatorSnapshot,
}))

vi.mock('../../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess,
}))

import { FlowControlPanel } from './flow-control-panel'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

describe('FlowControlPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    flowState.value = 'running'
    flowLoading.value = false
    maintenanceResult.value = null
    maintenanceLoading.value = false
    shellAuthSummary.value = null
    operatorSnapshot.value = null
    dashboardAuthAccess.mockImplementation((_summary, requiredRole: 'worker' | 'admin') => ({
      allowed: requiredRole === 'worker',
      required_role: requiredRole,
      effective_role: 'worker',
      reason: requiredRole === 'worker' ? null : 'admin role is required',
    }))
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('shows core flow controls without a dedicated refresh button', async () => {
    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-command-surface')).not.toBeNull()
    expect(container.textContent).toContain('Flow Control')
    expect(container.textContent).toContain('Pause')
    expect(container.textContent).toContain('Resume')
    expect(container.textContent).not.toContain('Refresh')
  })

  it('shows the exact Agent Core inference observation when present', async () => {
    operatorSnapshot.value = {
      inference_inflight: {
        boundary_owner: 'agent_core_runtime',
        active: 1,
      },
    }

    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    const status = container.querySelector('[data-testid="flow-inference-inflight"]')
    expect(status).not.toBeNull()
    expect(status!.textContent).toContain('agent_core_runtime')
    expect(status!.textContent).toContain('1 active inference')
  })

  it('keeps worker flow controls enabled but disables admin-only GC', async () => {
    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    const buttons = Array.from(container.querySelectorAll('button'))
    const pause = buttons.find((button) => button.textContent?.includes('Pause'))
    const gc = buttons.find((button) => button.textContent?.includes('Run GC'))
    expect(pause?.disabled).toBe(false)
    expect(gc?.disabled).toBe(true)
    expect(dashboardAuthAccess).toHaveBeenCalledWith(null, 'admin')
  })

})
