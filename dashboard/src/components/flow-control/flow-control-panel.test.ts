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
  flowState: { value: 'running' as 'running' | 'paused' | 'initializing' | 'stopped' | 'unknown' },
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

    expect(container.textContent).toContain('Flow Control')
    expect(container.textContent).toContain('Pause')
    expect(container.textContent).toContain('Resume')
    expect(container.textContent).not.toContain('Refresh')
  })

  it('shows admission queue mode and throttle owner when present', async () => {
    operatorSnapshot.value = {
      admission_queue: {
        mode: 'passthrough',
        throttle_owner: 'oas_runtime',
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
    expect(status!.textContent).toContain('OAS runtime')
    expect(status!.textContent).toContain('1/3')
  })

  it('shows stopped fleet admission as a dedicated flow state', async () => {
    flowState.value = 'stopped'

    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Stopped')
    const buttons = Array.from(container.querySelectorAll('button'))
    const pause = buttons.find(button => button.textContent?.includes('Pause'))
    const resume = buttons.find(button => button.textContent?.includes('Resume'))
    expect(pause).toHaveProperty('disabled', true)
    expect(resume).toHaveProperty('disabled', false)
  })
})
