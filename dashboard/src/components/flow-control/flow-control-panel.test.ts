import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const fetchPauseStatus = vi.fn().mockResolvedValue(undefined)
const pauseRoom = vi.fn().mockResolvedValue(undefined)
const resumeRoom = vi.fn().mockResolvedValue(undefined)
const fetchRoomStrategy = vi.fn().mockResolvedValue(undefined)
const runGarbageCollection = vi.fn().mockResolvedValue(undefined)
const cleanupZombies = vi.fn().mockResolvedValue(undefined)

const flowState = { value: 'running' as 'running' | 'paused' | 'initializing' | 'unknown' }
const flowLoading = { value: false }
const roomStrategy = { value: null as Record<string, unknown> | null }
const roomStrategyLoading = { value: false }
const maintenanceResult = { value: null as string | null }
const maintenanceLoading = { value: false }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadPanel() {
  vi.resetModules()
  vi.doMock('./flow-control-state', () => ({
    cleanupZombies,
    fetchPauseStatus,
    fetchRoomStrategy,
    flowLoading,
    flowState,
    maintenanceLoading,
    maintenanceResult,
    pauseRoom,
    resumeRoom,
    roomStrategy,
    roomStrategyLoading,
    runGarbageCollection,
  }))
  return import('./flow-control-panel')
}

describe('FlowControlPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    flowState.value = 'running'
    flowLoading.value = false
    roomStrategy.value = null
    roomStrategyLoading.value = false
    maintenanceResult.value = null
    maintenanceLoading.value = false
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('./flow-control-state')
  })

  it('shows core flow controls without a dedicated refresh button', async () => {
    const { FlowControlPanel } = await loadPanel()

    render(html`<${FlowControlPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('흐름 제어')
    expect(container.textContent).toContain('일시정지')
    expect(container.textContent).toContain('재개')
    expect(container.textContent).not.toContain('새로고침')
  }, 60_000)
})
