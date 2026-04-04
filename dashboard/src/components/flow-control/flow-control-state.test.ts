import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { callMcpTool } = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool,
}))

describe('flow-control-state', () => {
  beforeEach(async () => {
    vi.resetModules()
    callMcpTool.mockReset()
    const { flowState } = await import('./flow-control-state')
    flowState.value = 'unknown'
  })

  afterEach(async () => {
    const { flowState } = await import('./flow-control-state')
    flowState.value = 'unknown'
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
