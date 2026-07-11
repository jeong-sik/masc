import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  callMcpTool,
  confirmOperatorPendingAction,
  currentDashboardActor,
  dispatchOperatorAction,
  fetchOperatorSnapshot,
  namespaceTruth,
  namespaceTruthInitializing,
  serverStatus,
  shellAuthSummary,
  showToast,
} = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  confirmOperatorPendingAction: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard-test'),
  dispatchOperatorAction: vi.fn(),
  fetchOperatorSnapshot: vi.fn(),
  namespaceTruth: { value: null as unknown },
  namespaceTruthInitializing: { value: false },
  serverStatus: { value: null as unknown },
  shellAuthSummary: { value: null as unknown },
  showToast: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool,
}))

vi.mock('../../api/core', () => ({
  currentDashboardActor,
  fetchOperatorSnapshot,
}))

vi.mock('../../operator-actions', () => ({
  confirmOperatorPendingAction,
  dispatchOperatorAction,
}))

vi.mock('../../namespace-truth-store', () => ({
  namespaceTruth,
  namespaceTruthInitializing,
}))

vi.mock('../../store', () => ({
  serverStatus,
  shellAuthSummary,
}))

vi.mock('../common/toast', () => ({
  showToast,
}))

import {
  fetchPauseStatus,
  flowState,
  pauseWorkspace,
  resumeWorkspace,
} from './flow-control-state'

describe('flow-control-state', () => {
  beforeEach(() => {
    callMcpTool.mockReset()
    confirmOperatorPendingAction.mockReset()
    currentDashboardActor.mockReset()
    currentDashboardActor.mockReturnValue('dashboard-test')
    dispatchOperatorAction.mockReset()
    fetchOperatorSnapshot.mockReset()
    showToast.mockReset()
    namespaceTruth.value = null
    namespaceTruthInitializing.value = false
    serverStatus.value = null
    shellAuthSummary.value = {
      effective_role: 'admin',
      default_role: 'admin',
      auth_error_code: null,
      auth_error_detail: null,
    }
    flowState.value = 'unknown'
  })

  afterEach(() => {
    flowState.value = 'unknown'
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('reuses project snapshot pause state before fetching operator state', async () => {
    namespaceTruth.value = {
      root: {
        status: {
          paused: true,
        },
      },
    }

    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
    expect(fetchOperatorSnapshot).not.toHaveBeenCalled()
  })

  it('treats project snapshot warm-up as initializing before fetching operator state', async () => {
    namespaceTruthInitializing.value = true

    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
    expect(fetchOperatorSnapshot).not.toHaveBeenCalled()
  })

  it('keeps initializing workspaces out of the running state', async () => {
    fetchOperatorSnapshot.mockResolvedValueOnce({
      workspace: { initialized: false },
    })

    await fetchPauseStatus()

    expect(flowState.value).toBe('initializing')
  })

  it('marks paused workspaces as paused', async () => {
    fetchOperatorSnapshot.mockResolvedValueOnce({
      workspace: { initialized: true, paused: true },
    })

    await fetchPauseStatus()

    expect(flowState.value).toBe('paused')
  })

  it('marks active workspaces as running', async () => {
    fetchOperatorSnapshot.mockResolvedValueOnce({
      workspace: { initialized: true, paused: false },
    })

    await fetchPauseStatus()

    expect(flowState.value).toBe('running')
  })

  it('fails safe to unknown when the operator snapshot omits workspace state', async () => {
    fetchOperatorSnapshot.mockResolvedValueOnce({ workspace: {} })

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
    fetchOperatorSnapshot.mockResolvedValueOnce({
      workspace: { initialized: true, paused: false },
    })
    await fetchPauseStatus()
    expect(flowState.value).toBe('running')
  })

  it('pauses through operator action and explicit confirmation', async () => {
    dispatchOperatorAction.mockResolvedValueOnce({
      status: 'pending_confirm',
      confirm_required: true,
      confirm_token: 'pause-token',
      preview: { action_type: 'namespace_pause' },
    })
    confirmOperatorPendingAction.mockResolvedValueOnce({ status: 'ok' })
    vi.stubGlobal('confirm', vi.fn().mockReturnValue(true))

    await pauseWorkspace()

    expect(dispatchOperatorAction).toHaveBeenCalledExactlyOnceWith({
      actor: 'dashboard-test',
      action_type: 'namespace_pause',
      target_type: 'workspace',
      payload: { reason: 'Paused from the dashboard flow-control panel.' },
    })
    expect(confirmOperatorPendingAction).toHaveBeenCalledExactlyOnceWith(
      'dashboard-test',
      'pause-token',
      'confirm',
    )
    expect(flowState.value).toBe('paused')
  })

  it('resumes through the immediate operator action', async () => {
    dispatchOperatorAction.mockResolvedValueOnce({
      status: 'ok',
      confirm_required: false,
    })

    await resumeWorkspace()

    expect(dispatchOperatorAction).toHaveBeenCalledExactlyOnceWith({
      actor: 'dashboard-test',
      action_type: 'namespace_resume',
      target_type: 'workspace',
      payload: {},
    })
    expect(confirmOperatorPendingAction).not.toHaveBeenCalled()
    expect(flowState.value).toBe('running')
  })

  it('requires admin permission for namespace lifecycle actions', async () => {
    shellAuthSummary.value = {
      effective_role: 'worker',
      default_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }

    await pauseWorkspace()

    expect(dispatchOperatorAction).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith(
      expect.stringContaining('admin role is required'),
      'error',
      6000,
    )
  })
})
