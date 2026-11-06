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
  runGarbageCollection,
  maintenanceResult,
  maintenanceLoading,
  shellAuthSummary,
  operatorSnapshot,
  dashboardAuthAccess,
} = vi.hoisted(() => ({
  runGarbageCollection: vi.fn().mockResolvedValue(undefined),
  maintenanceResult: { value: null as string | null },
  maintenanceLoading: { value: false },
  shellAuthSummary: { value: null },
  operatorSnapshot: { value: null as MockOperatorSnapshot },
  dashboardAuthAccess: vi.fn(),
}))

vi.mock('./flow-control-state', () => ({
  maintenanceLoading,
  maintenanceResult,
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

  it('disables GC for a worker', async () => {
    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    const gc = Array.from(container.querySelectorAll('button'))
      .find((button) => button.textContent?.includes('Run GC'))
    expect(gc?.disabled).toBe(true)
    expect(dashboardAuthAccess).toHaveBeenCalledWith(null, 'admin')
  })

})
