import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

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
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('shows core flow controls without a dedicated refresh button', async () => {
    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('흐름 제어')
    expect(container.textContent).toContain('일시정지')
    expect(container.textContent).toContain('재개')
    expect(container.textContent).not.toContain('새로고침')
  })
})
