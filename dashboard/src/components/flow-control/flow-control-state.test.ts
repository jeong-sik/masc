import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  callMcpTool,
  namespaceTruth,
  namespaceTruthInitializing,
  serverStatus,
  shellAuthSummary,
} = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  namespaceTruth: { value: null as unknown },
  namespaceTruthInitializing: { value: false },
  serverStatus: { value: null as unknown },
  shellAuthSummary: { value: null as unknown },
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool,
}))

vi.mock('../../namespace-truth-store', () => ({
  namespaceTruth,
  namespaceTruthInitializing,
}))

vi.mock('../../store', () => ({
  serverStatus,
  shellAuthSummary,
}))

import {
  fetchPauseStatus,
  flowState,
} from './flow-control-state'

describe('flow-control-state', () => {
  beforeEach(() => {
    callMcpTool.mockReset()
    namespaceTruth.value = null
    namespaceTruthInitializing.value = false
    serverStatus.value = null
    shellAuthSummary.value = {
      effective_role: 'worker',
      default_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }
    flowState.value = 'unknown'
  })

  afterEach(() => {
    flowState.value = 'unknown'
  })

  it('reuses project snapshot pause state before calling MCP', async () => {
    namespaceTruth.value = {
      root: {
        status: {
          paused: true,
        },
      },
    }

    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('treats project snapshot warm-up as initializing before calling MCP', async () => {
    namespaceTruthInitializing.value = true

    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('keeps initializing rooms out of the running state', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'initializing', initializing: true, paused: null }),
    )

    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
  })

  it('marks paused rooms as paused', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'paused', paused: true }),
    )

    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
  })

  it('trims status strings before matching pause state', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: ' paused ', paused: null }),
    )

    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
  })

  it('fails safe to unknown for unexpected status strings', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'mystery', paused: null, initializing: false }),
    )

    await fetchPauseStatus()

    expect(flowState.value).toBe('unknown')
  })

  it('recomputes from project-snapshot signals on the next fetch', async () => {
    namespaceTruthInitializing.value = true
    await fetchPauseStatus()
    expect(flowState.value).toBe('initializing')

    namespaceTruthInitializing.value = false
    namespaceTruth.value = {
      root: {
        status: {
          paused: false,
        },
      },
    }
    await fetchPauseStatus()
    expect(flowState.value).toBe('running')
  })
})
