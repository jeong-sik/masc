import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  dispatchOperatorAction: vi.fn(),
  confirmOperatorPendingAction: vi.fn(),
  requestConfirm: vi.fn(),
  refreshNamespaceTruth: vi.fn(),
  namespaceTruth: { value: null as unknown },
  namespaceTruthInitializing: { value: false },
  namespaceTruthError: { value: null as string | null },
  serverStatus: { value: null as unknown },
  shellAuthSummary: { value: null as unknown },
  showToast: vi.fn(),
}))
vi.mock('../../api/mcp', () => ({ callMcpTool: mocks.callMcpTool }))
vi.mock('../../api/core', () => ({ currentDashboardActor: () => 'test-operator' }))
vi.mock('../../operator-store', () => ({
  dispatchOperatorAction: mocks.dispatchOperatorAction,
  confirmOperatorPendingAction: mocks.confirmOperatorPendingAction,
}))
vi.mock('../../namespace-truth-store', () => ({
  namespaceTruth: mocks.namespaceTruth,
  namespaceTruthInitializing: mocks.namespaceTruthInitializing,
  namespaceTruthError: mocks.namespaceTruthError,
  refreshNamespaceTruth: mocks.refreshNamespaceTruth,
}))
vi.mock('../../store', () => ({
  serverStatus: mocks.serverStatus,
  shellAuthSummary: mocks.shellAuthSummary,
}))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../common/confirm-dialog', () => ({ requestConfirm: mocks.requestConfirm }))

let fetchPauseStatus: typeof import('./flow-control-state').fetchPauseStatus
let flowState: typeof import('./flow-control-state').flowState
let flowLoading: typeof import('./flow-control-state').flowLoading
let pauseWorkspace: typeof import('./flow-control-state').pauseWorkspace
let resumeWorkspace: typeof import('./flow-control-state').resumeWorkspace
let runGarbageCollection: typeof import('./flow-control-state').runGarbageCollection

function snapshot(paused: boolean): void {
  mocks.namespaceTruth.value = { root: { status: { paused } } }
}

describe('flow-control-state', () => {
  beforeEach(async () => {
    vi.resetModules()
    vi.resetAllMocks()
    mocks.namespaceTruth.value = null
    mocks.namespaceTruthInitializing.value = false
    mocks.namespaceTruthError.value = null
    mocks.serverStatus.value = null
    mocks.shellAuthSummary.value = {
      effective_role: 'admin', auth_error_code: null, auth_error_detail: null,
    }
    ;({ fetchPauseStatus, flowState, flowLoading, pauseWorkspace, resumeWorkspace, runGarbageCollection } = await import('./flow-control-state'))
    flowState.value = 'unknown'
    flowLoading.value = false
    mocks.dispatchOperatorAction.mockResolvedValue({
      status: 'pending_confirm', confirm_required: true, confirm_token: 'token-1',
    })
    mocks.confirmOperatorPendingAction.mockResolvedValue({ status: 'ok' })
    mocks.requestConfirm.mockResolvedValue(true)
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ ok: true, initializing: false, paused: true }))
  })
  afterEach(() => { flowState.value = 'unknown' })

  it('uses an existing paused snapshot without raw MCP', async () => {
    snapshot(true)
    await fetchPauseStatus()
    expect(flowState.value).toBe('paused')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.refreshNamespaceTruth).not.toHaveBeenCalled()
  })

  it('revalidates cached running state when another client has paused', async () => {
    snapshot(false)
    await fetchPauseStatus()
    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_pause_status', {})
    expect(flowState.value).toBe('paused')
  })

  it('withdraws cached running state when direct pause status is unavailable', async () => {
    snapshot(false)
    mocks.callMcpTool.mockRejectedValue(new Error('unavailable'))
    await fetchPauseStatus()
    expect(flowState.value).toBe('unknown')
  })

  it('loads missing pause status from namespace truth', async () => {
    mocks.refreshNamespaceTruth.mockImplementation(async () => snapshot(true))
    await fetchPauseStatus()
    expect(mocks.refreshNamespaceTruth).toHaveBeenCalledWith({ force: true })
    expect(flowState.value).toBe('paused')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('revalidates running after the initial forced projection read', async () => {
    mocks.refreshNamespaceTruth.mockImplementation(async () => snapshot(false))
    await fetchPauseStatus()
    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_pause_status', {})
    expect(flowState.value).toBe('paused')
  })

  it('retains initializing and unknown states', async () => {
    mocks.namespaceTruthInitializing.value = true
    await fetchPauseStatus()
    expect(flowState.value).toBe('initializing')
    mocks.namespaceTruthInitializing.value = false
    await fetchPauseStatus()
    expect(flowState.value).toBe('unknown')
  })

  it.each([
    ['namespace_resume', () => resumeWorkspace(), true, false, 'Namespace resumed.'],
    ['namespace_pause', () => pauseWorkspace(), false, true, 'Namespace paused.'],
  ] as const)('confirms %s then reads its result', async (action, run, before, after, message) => {
    snapshot(before)
    mocks.refreshNamespaceTruth.mockImplementation(async () => snapshot(before))
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ ok: true, initializing: false, paused: after }))
    await run()
    expect(mocks.dispatchOperatorAction).toHaveBeenCalledWith({
      actor: 'test-operator', action_type: action, target_type: 'workspace', payload: {},
    }, { refresh: 'background' })
    expect(mocks.requestConfirm).toHaveBeenCalledTimes(1)
    expect(mocks.confirmOperatorPendingAction).toHaveBeenCalledWith('test-operator', 'token-1', 'confirm', { refresh: 'background' })
    expect(mocks.refreshNamespaceTruth).toHaveBeenCalledWith({ force: true })
    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_pause_status', {})
    expect(flowState.value).toBe(after ? 'paused' : 'running')
    expect(mocks.showToast).toHaveBeenCalledWith(message, 'success')
    expect(flowLoading.value).toBe(false)
  })

  it('reads and acknowledges before an unrelated namespace refresh completes', async () => {
    let finishRefresh!: () => void
    mocks.refreshNamespaceTruth.mockImplementation(() => new Promise<void>(resolve => { finishRefresh = resolve }))
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({ ok: true, initializing: false, paused: false }))
    await resumeWorkspace()
    expect(mocks.showToast).toHaveBeenCalledWith('Namespace resumed.', 'success')
    expect(flowLoading.value).toBe(false)
    expect(mocks.callMcpTool.mock.invocationCallOrder[0]).toBeLessThan(mocks.refreshNamespaceTruth.mock.invocationCallOrder[0]!)
    finishRefresh()
  })

  it('denies the pending action when the dialog is cancelled', async () => {
    snapshot(true)
    mocks.requestConfirm.mockResolvedValue(false)
    await fetchPauseStatus()
    await resumeWorkspace()
    expect(mocks.confirmOperatorPendingAction).toHaveBeenCalledWith('test-operator', 'token-1', 'deny', { refresh: 'background' })
    expect(flowState.value).toBe('paused')
    expect(mocks.showToast).not.toHaveBeenCalledWith('Namespace resumed.', 'success')
  })

  it('does not label a still-paused namespace as resumed', async () => {
    snapshot(true)
    await resumeWorkspace()
    expect(flowState.value).toBe('paused')
    expect(mocks.showToast).not.toHaveBeenCalledWith('Namespace resumed.', 'success')
  })

  it('does not claim success when readback fails, even with stale running status', async () => {
    snapshot(true)
    mocks.serverStatus.value = { paused: false }
    mocks.callMcpTool.mockRejectedValue(new Error('readback failed'))
    mocks.refreshNamespaceTruth.mockImplementation(async () => {
      mocks.namespaceTruth.value = null
      mocks.namespaceTruthError.value = 'readback failed'
    })
    await resumeWorkspace()
    expect(flowState.value).toBe('unknown')
    expect(mocks.showToast).not.toHaveBeenCalledWith('Namespace resumed.', 'success')
  })

  it('preserves pause state and releases loading after confirmation fails', async () => {
    snapshot(true)
    await fetchPauseStatus()
    mocks.confirmOperatorPendingAction.mockRejectedValue(new Error('expired token'))
    await resumeWorkspace()
    expect(flowState.value).toBe('paused')
    expect(flowLoading.value).toBe(false)
    expect(mocks.showToast).toHaveBeenCalledWith('Resume failed: expired token', 'error')
  })

  it('never confirms without a server token', async () => {
    mocks.dispatchOperatorAction.mockResolvedValue({ status: 'pending_confirm', confirm_required: true })
    await resumeWorkspace()
    expect(mocks.requestConfirm).not.toHaveBeenCalled()
    expect(mocks.confirmOperatorPendingAction).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('confirmation token'), 'error')
  })

  it('blocks overlapping clicks while confirmation is open', async () => {
    let resolveDialog!: (value: boolean) => void
    mocks.requestConfirm.mockImplementation(() => new Promise<boolean>(resolve => { resolveDialog = resolve }))
    const first = resumeWorkspace()
    await vi.waitFor(() => expect(mocks.requestConfirm).toHaveBeenCalledTimes(1))
    await resumeWorkspace()
    expect(mocks.dispatchOperatorAction).toHaveBeenCalledTimes(1)
    resolveDialog(false)
    await first
  })

  it.each([
    { ok: true, initializing: false, paused: null },
    { ok: true, initializing: true, paused: false },
    { ok: false, initializing: false, paused: false },
    { ok: true, initializing: false, any_pause_active: false },
  ])('rejects unavailable Workspace readback %j', async readback => {
    snapshot(false)
    mocks.callMcpTool.mockResolvedValue(JSON.stringify(readback))
    await resumeWorkspace()
    expect(flowState.value).toBe('unknown')
    expect(mocks.showToast).not.toHaveBeenCalledWith('Namespace resumed.', 'success')
    expect(mocks.showToast).toHaveBeenCalledWith('Resume failed: Namespace pause readback is unavailable.', 'error')
  })

  it('rejects a reader before creating a pending action', async () => {
    mocks.shellAuthSummary.value = { effective_role: 'reader' }
    await resumeWorkspace()
    expect(mocks.dispatchOperatorAction).not.toHaveBeenCalled()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith('Current role is reader; admin role is required.', 'error', 6000)
  })

  it.each([() => pauseWorkspace(), () => resumeWorkspace()])('rejects worker namespace actions before dispatch', async run => {
    mocks.shellAuthSummary.value = { effective_role: 'worker' }
    await run()
    expect(mocks.dispatchOperatorAction).not.toHaveBeenCalled()
    expect(mocks.requestConfirm).not.toHaveBeenCalled()
    expect(mocks.confirmOperatorPendingAction).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith('Current role is worker; admin role is required.', 'error', 6000)
  })

  it('rejects garbage collection for a worker', async () => {
    mocks.shellAuthSummary.value = { effective_role: 'worker' }
    await runGarbageCollection()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith('Current role is worker; admin role is required.', 'error', 6000)
  })

  it('runs garbage collection for an admin', async () => {
    mocks.shellAuthSummary.value = { effective_role: 'admin' }
    mocks.callMcpTool.mockResolvedValue('{ "removed": 0 }')
    await runGarbageCollection()
    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_gc', {})
  })
})
