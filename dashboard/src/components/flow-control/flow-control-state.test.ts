import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { callMcpTool } = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
}))

const namespaceTruth = { value: null as unknown }
const namespaceTruthInitializing = { value: false }
const serverStatus = { value: null as unknown }

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
  })

  afterEach(async () => {
    const { flowState } = await import('./flow-control-state')
    flowState.value = 'unknown'
  })

  it('reuses namespace truth pause state before calling MCP', async () => {
    namespaceTruth.value = {
      namespace: {
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
})
