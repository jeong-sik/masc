import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type MockOperatorSnapshot = {
  inference_inflight?: {
    boundary_owner: 'oas_runtime'
    active: number
  } | null
} | null

const {
  fetchPauseStatus,
  pauseWorkspace,
  resumeWorkspace,
  runGarbageCollection,
  cleanupZombies,
  flowState,
  flowLoading,
  maintenanceResult,
  maintenanceLoading,
  shellAuthSummary,
  operatorSnapshot,
} = vi.hoisted(() => ({
  fetchPauseStatus: vi.fn().mockResolvedValue(undefined),
  pauseWorkspace: vi.fn().mockResolvedValue(undefined),
  resumeWorkspace: vi.fn().mockResolvedValue(undefined),
  runGarbageCollection: vi.fn().mockResolvedValue(undefined),
  cleanupZombies: vi.fn().mockResolvedValue(undefined),
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' },
  flowLoading: { value: false },
  maintenanceResult: { value: null as string | null },
  maintenanceLoading: { value: false },
  shellAuthSummary: { value: null },
  operatorSnapshot: { value: null as MockOperatorSnapshot },
}))

vi.mock('./flow-control-state', () => ({
  cleanupZombies,
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
  dashboardAuthAccess: () => ({
    allowed: true,
    required_role: 'worker',
    effective_role: 'worker',
    reason: null,
  }),
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

  it('shows the exact OAS inference observation when present', async () => {
    operatorSnapshot.value = {
      inference_inflight: {
        boundary_owner: 'oas_runtime',
        active: 1,
      },
    }

    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    const status = container.querySelector('[data-testid="flow-inference-inflight"]')
    expect(status).not.toBeNull()
    expect(status!.textContent).toContain('oas_runtime')
    expect(status!.textContent).toContain('1 active inference')
  })

})
