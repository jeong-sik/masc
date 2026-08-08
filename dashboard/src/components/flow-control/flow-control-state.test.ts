import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  callMcpTool,
  namespaceTruth,
  namespaceTruthInitializing,
  serverStatus,
  shellAuthSummary,
  showToast,
} = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  namespaceTruth: { value: null as unknown },
  namespaceTruthInitializing: { value: false },
  serverStatus: { value: null as unknown },
  shellAuthSummary: { value: null as unknown },
  showToast: vi.fn(),
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

vi.mock('../common/toast', () => ({ showToast }))

import {
  fetchPauseStatus,
  flowState,
  runGarbageCollection,
} from './flow-control-state'

describe('flow-control-state', () => {
  beforeEach(() => {
    callMcpTool.mockReset()
    namespaceTruth.value = null
    namespaceTruthInitializing.value = false
    serverStatus.value = null
    shellAuthSummary.value = {
      effective_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }
    flowState.value = 'unknown'
    showToast.mockReset()
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

  it('keeps initializing workspaces out of the running state', async () => {
    callMcpTool.mockResolvedValueOnce(
      JSON.stringify({ status: 'initializing', initializing: true, paused: null }),
    )

    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
  })

  it('marks paused workspaces as paused', async () => {
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
    callMcpTool.mockResolvedValueOnce(JSON.stringify({ status: 'running', paused: false }))
    await fetchPauseStatus()
    expect(flowState.value).toBe('running')
  })

  it('rejects garbage collection for a worker before calling MCP', async () => {
    await runGarbageCollection()

    expect(callMcpTool).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith(
      'Current role is worker; admin role is required.',
      'error',
      6000,
    )
  })

  it('runs garbage collection for an admin', async () => {
    shellAuthSummary.value = {
      effective_role: 'admin',
      auth_error_code: null,
      auth_error_detail: null,
    }
    callMcpTool.mockResolvedValueOnce('{"removed":0}')

    await runGarbageCollection()

    expect(callMcpTool).toHaveBeenCalledWith('masc_gc', {})
  })
})
