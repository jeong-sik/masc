import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type MockOperatorSnapshot = {
  admission_queue?: {
    mode: string
    throttle_owner: string
    max_concurrent: number
    active: number
    available: number
    queue_depth: number
  } | null
} | null

const {
  fetchPauseStatus,
  pauseRoom,
  resumeRoom,
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
  pauseRoom: vi.fn().mockResolvedValue(undefined),
  resumeRoom: vi.fn().mockResolvedValue(undefined),
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
  pauseRoom,
  resumeRoom,
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

    expect(container.textContent).toContain('Flow Control')
    expect(container.textContent).toContain('Pause')
    expect(container.textContent).toContain('Resume')
    expect(container.textContent).not.toContain('Refresh')
  })

  it('shows admission queue mode and throttle owner when present', async () => {
    operatorSnapshot.value = {
      admission_queue: {
        mode: 'passthrough',
        throttle_owner: 'oas_cascade',
        max_concurrent: 3,
        active: 1,
        available: 2,
        queue_depth: 0,
      },
    }

    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    const status = container.querySelector('[data-testid="flow-admission-mode"]')
    expect(status).not.toBeNull()
    expect(status!.textContent).toContain('passthrough')
    expect(status!.textContent).toContain('OAS cascade')
    expect(status!.textContent).toContain('1/3')
  })
})
