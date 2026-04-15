import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'

const { callMcpTool } = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
}))

const namespaceTruth = signal<unknown>(null)
const namespaceTruthInitializing = signal(false)
const serverStatus = signal<unknown>(null)

vi.mock('../../api/mcp', () => ({
  callMcpTool,
}))

vi.mock('../../namespace-truth-store', () => ({
  namespaceTruth,
  namespaceTruthInitializing,
}))

vi.mock('../../store', () => ({
  serverStatus,
}))

describe('flow-control-state', () => {
  beforeEach(async () => {
    vi.resetModules()
    callMcpTool.mockReset()
    namespaceTruth.value = null
    namespaceTruthInitializing.value = false
    serverStatus.value = null
    const { flowState } = await import('./flow-control-state')
    flowState.value = 'unknown'
  }, 60_000)

  afterEach(async () => {
    const { flowState } = await import('./flow-control-state')
    flowState.value = 'unknown'
  }, 60_000)

  it('reuses namespace truth pause state before calling MCP', async () => {
    namespaceTruth.value = {
      root: {
        status: {
          paused: true,
        },
      },
    }

    const { fetchPauseStatus, flowState } = await import('./flow-control-state')
    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('treats namespace truth warm-up as initializing before calling MCP', async () => {
    namespaceTruthInitializing.value = true

    const { fetchPauseStatus, flowState } = await import('./flow-control-state')
    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('keeps initializing rooms out of the running state', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'initializing', initializing: true, paused: null }),
    )

    const { fetchPauseStatus, flowState } = await import('./flow-control-state')
    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
  })

  it('marks paused rooms as paused', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'paused', paused: true }),
    )

    const { fetchPauseStatus, flowState } = await import('./flow-control-state')
    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
  })

  it('reacts to namespace-truth signal changes after mount', async () => {
    const { flowState } = await import('./flow-control-state')

    namespaceTruthInitializing.value = true
    expect(flowState.value).toBe('initializing')

    namespaceTruthInitializing.value = false
    namespaceTruth.value = {
      root: {
        status: {
          paused: false,
        },
      },
    }
    expect(flowState.value).toBe('running')
  })
})
