// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { _testResetTaskCreateState, showTaskCreate, taskCreating, createTask, assignTaskToGoal } from './task-manage-state'
import { clearStoredToken, currentDashboardActor, currentStoredTokenRevision, setStoredToken } from '../../api/core'
import { noteManagedCredentialRefusalObservation, recordManagedCredentialRefusal, resetDashboardSessionActorForTests,
  setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'

const mockCallMcpToolAtIdentity = vi.fn()
const mockFailureDisposition = vi.fn<(error: unknown) => string>(() => 'outcome_unknown')
const mockShowToast = vi.fn()
const mockRefreshExecution = vi.fn()
const mockRefreshGoals = vi.fn()
const mockRefreshShell = vi.fn()
const mockCaptureWorkspace = vi.fn()
const mockRetryRejectedDevToken = vi.fn()
const mockAuthority = { peek: vi.fn() }
const mockWorkspaceRevision = { peek: vi.fn() }
const mockExecutionError = { peek: vi.fn() }
const mockLastGoalsRefreshAt = { peek: vi.fn() }
const mockTasks = { peek: vi.fn() }
const authorityA = { epoch: 'epoch-a', workspaceRoot: '/a', connectionGeneration: 1 }
const identity = () => ({ revision: currentStoredTokenRevision(), actor: currentDashboardActor() })
const created = (args: Record<string, unknown>) => JSON.stringify({ ok: true,
  creation_request_id: args.creation_request_id, goal_id: args.goal_id ?? null, task_id: 'task-1' })
function firstCallArgs(): Record<string, unknown> {
  const args: unknown = mockCallMcpToolAtIdentity.mock.calls[0]?.[1]
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Missing MCP call arguments')
  return args as Record<string, unknown>
}

vi.mock('../../api/mcp', () => ({ callMcpToolAtIdentity: (...args: any[]) => mockCallMcpToolAtIdentity(...args),
  callMcpTaskCreationAtIdentity: (args: unknown, identity: unknown, current: unknown, recovery: unknown, wait: unknown) =>
    mockCallMcpToolAtIdentity('masc_add_task', args, identity, current, recovery, wait),
  mcpCallFailureDisposition: (error: unknown) => mockFailureDisposition(error) }))
vi.mock('../../api/dev-token', () => ({ retryRejectedDevToken: (...args: any[]) => mockRetryRejectedDevToken(...args) }))
vi.mock('../../api/published-artifacts', () => ({
  captureArtifactWorkspace: (...args: any[]) => mockCaptureWorkspace(...args),
  artifactWorkspaceBody: (workspace: { basePath: string; mascRoot: string }) =>
    ({ base_path: workspace.basePath, masc_root: workspace.mascRoot }),
}))
vi.mock('../common/toast', () => ({ showToast: (...args: any[]) => mockShowToast(...args) }))
vi.mock('../../store', () => ({
  executionWorkspaceAuthority: { peek: () => mockAuthority.peek() },
  executionWorkspaceRevision: { peek: () => mockWorkspaceRevision.peek() },
  executionError: { peek: () => mockExecutionError.peek() },
  lastGoalsRefreshAt: { peek: () => mockLastGoalsRefreshAt.peek() },
  tasks: { peek: () => mockTasks.peek() },
  refreshExecution: (...args: any[]) => mockRefreshExecution(...args),
  refreshGoals: () => mockRefreshGoals(),
  refreshShell: (...args: any[]) => mockRefreshShell(...args),
}))


describe('task-manage-state', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    clearStoredToken()
    resetDashboardSessionActorForTests()
    _testResetTaskCreateState()
    mockCallMcpToolAtIdentity.mockReset()
    mockFailureDisposition.mockReset().mockReturnValue('outcome_unknown')
    mockShowToast.mockReset()
    mockRefreshExecution.mockReset()
    mockRefreshGoals.mockReset()
    mockRefreshShell.mockReset()
    mockCaptureWorkspace.mockReset()
    mockRetryRejectedDevToken.mockReset()
    mockAuthority.peek.mockReturnValue(authorityA)
    mockWorkspaceRevision.peek.mockReturnValue(1)
    mockExecutionError.peek.mockReturnValue(null)
    mockTasks.peek.mockReturnValue([{ id: 'task-1' }])
    mockCaptureWorkspace.mockResolvedValue({ basePath: '/a', mascRoot: '/a/.masc' })
    mockRetryRejectedDevToken.mockResolvedValue(false)
    mockRefreshShell.mockResolvedValue(true)
    mockCallMcpToolAtIdentity.mockImplementation(async (_name: string, args: Record<string, unknown>) => created(args))
    mockRefreshExecution.mockResolvedValue(undefined)
    mockRefreshGoals.mockResolvedValue(undefined)
  })

  afterEach(() => {
    clearStoredToken()
    resetDashboardSessionActorForTests()
    vi.clearAllMocks()
  })

  it('showTaskCreate defaults to false', () => {
    expect(showTaskCreate.value).toBe(false)
  })

  it('taskCreating defaults to false', () => {
    expect(taskCreating.value).toBe(false)
  })

  it('createTask rejects empty title and shows error toast', async () => {
    const result = await createTask({ title: '   ', description: '' })
    expect(result).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith('제목을 입력하세요', 'error')
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it('createTask calls masc_add_task with trimmed title and description', async () => {
    const result = await createTask({ title: '  my task  ', description: '  desc  ' })
    expect(mockCaptureWorkspace).toHaveBeenCalledWith('/a', undefined, { reportCredentialRefusal: false })
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({
      title: 'my task', description: 'desc', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' },
      creation_request_id: expect.any(String),
    }), expect.objectContaining({ revision: expect.any(Number), actor: expect.any(String) }),
    expect.any(Function), expect.any(Function), undefined)
    expect(result).toBe(true)
  })

  it('createTask includes priority when provided', async () => {
    await createTask({ title: 't', description: '', priority: 2 })
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({ priority: 2 }),
      expect.any(Object), expect.any(Function), expect.any(Function), undefined)
  })

  it('refreshes a missing workspace observation and keeps the draft for a later retry', async () => {
    mockAuthority.peek.mockReturnValue(null)
    const finish = vi.fn(() => true)
    expect(await createTask({ title: 't', description: '' }, undefined, { finish })).toBe(false)
    expect(mockRefreshExecution).toHaveBeenCalledWith({ force: true })
    expect(mockCaptureWorkspace).not.toHaveBeenCalled()
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
    expect(finish).not.toHaveBeenCalled()
    mockAuthority.peek.mockReturnValue(authorityA)
    expect(await createTask({ title: 't', description: '' }, undefined, { finish })).toBe(true)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(finish).toHaveBeenCalledOnce()
  })

  it.each(['changed', 'changed and returned'] as const)(
    'does not post when the workspace %s during the health observation', async kind => {
      let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
      mockCaptureWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
      const finish = vi.fn(() => true)
      const pending = createTask({ title: 't', description: '' }, undefined, { finish })
      mockAuthority.peek.mockReturnValue({ epoch: 'epoch-b', workspaceRoot: '/b', connectionGeneration: 1 })
      if (kind === 'changed and returned') mockAuthority.peek.mockReturnValue({ ...authorityA })
      resolveWorkspace({ basePath: '/a', mascRoot: '/a/.masc' })
      expect(await pending).toBe(false)
      expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
      expect(finish).not.toHaveBeenCalled()
    },
  )

  it('does not post when the submitting draft or token changes during health observation', async () => {
    for (const change of ['draft', 'token'] as const) {
      let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
      let current = true
      mockCaptureWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
      const finish = vi.fn(() => true)
      const pending = createTask({ title: 't', description: '' }, undefined, { isCurrent: () => current, finish })
      if (change === 'draft') current = false
      else setStoredToken('new-token', { source: 'manual' })
      resolveWorkspace({ basePath: '/a', mascRoot: '/a/.masc' })
      expect(await pending).toBe(false)
      expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
      expect(finish).not.toHaveBeenCalled()
    }
  })

  it('rechecks an unclassified managed refusal before allowing a fresh submission', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    noteManagedCredentialRefusalObservation(revision)
    mockRefreshShell.mockImplementationOnce(async () => {
      setCanonicalDashboardActor('dashboard', { tokenRevision: revision, rejected: false, verifiedAfterRefusal: true })
      return true
    })
    expect(await createTask({ title: 't', description: '' })).toBe(false)
    expect(mockRefreshShell).toHaveBeenCalledWith({ force: true, recoverAuth: false })
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
    expect(await createTask({ title: 't', description: '' })).toBe(true)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledOnce()
  })

  it('retries confirmed managed authentication under the observed workspace, without posting a Task', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    recordManagedCredentialRefusal(currentStoredTokenRevision())
    expect(await createTask({ title: 't', description: '' })).toBe(false)
    expect(mockRetryRejectedDevToken).toHaveBeenCalledWith({ basePath: '/a', mascRoot: '/a/.masc' }, expect.any(Function))
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
    expect(mockRefreshShell).not.toHaveBeenCalled()
  })

  it('retains the recovery owner after a managed 401 observation without replaying the Task', async () => {
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = currentStoredTokenRevision()
    mockCallMcpToolAtIdentity.mockImplementationOnce(async (_tool, _args, _identity, isCurrent, isRecoveryCurrent) => {
      noteManagedCredentialRefusalObservation(revision)
      expect(isCurrent()).toBe(false)
      expect(isRecoveryCurrent()).toBe(true)
      throw new Error('401')
    })
    expect(await createTask({ title: 't', description: '' })).toBe(false)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mockShowToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
  })

  it('createTask preserves a canonical Goal ID and binds the observed workspace', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    await createTask({ title: 't', description: '', goal_id: '\u00a0g-123\u00a0' }, goalDispatch)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({
      goal_id: '\u00a0g-123\u00a0', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' },
    }), goalDispatch.identity, expect.any(Function), undefined, undefined)
  })

  it('refuses blank, padded, or stale Goal targets instead of making an unlinked Task', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    for (const goal_id of ['', '  g-123  ']) {
      expect(await createTask({ title: 't', description: '', goal_id }, goalDispatch)).toBe(false)
    }
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' },
      { ...goalDispatch, isCurrent: () => false })).toBe(false)
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it('keeps an uncertain Goal Task outcome distinct from a refusal', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('connection lost'))
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('결과를 확인할 수 없습니다'), 'warning')
    expect(mockShowToast).not.toHaveBeenCalledWith(expect.stringContaining('생성 실패'), 'error')
  })

  it.each([
    ['known_pre_effect', '생성 전에 요청이 거부'],
    ['known_tool_response', '서버가 오류를 반환'],
  ])('explains a %s Goal Task failure without exposing its raw detail', async (disposition, message) => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    mockFailureDisposition.mockReturnValue(disposition)
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('private server detail'))
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining(message), 'warning')
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('workspace'), 'warning')
    expect(JSON.stringify(mockShowToast.mock.calls)).not.toContain('private server detail')
  })

  it('does not expose a late Goal Task error after the owner changes', async () => {
    let current = true
    let rejectWrite!: (error: Error) => void
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => current }
    mockFailureDisposition.mockReturnValue('known_pre_effect')
    mockCallMcpToolAtIdentity.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectWrite = reject }))
    const pending = createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)
    current = false
    rejectWrite(new Error('private server detail'))
    expect(await pending).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
    expect(JSON.stringify(mockShowToast.mock.calls)).not.toContain('private server detail')
  })

  it('does not present a late Goal Task creation as the current owner success', async () => {
    let current = true
    let resolveCreate!: (value: string) => void
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => current }
    mockCallMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    showTaskCreate.value = true
    const pending = createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)
    current = false
    resolveCreate(created(firstCallArgs()))
    expect(await pending).toBe(true)
    expect(showTaskCreate.value).toBe(true)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
    expect(mockShowToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
    expect(mockRefreshGoals).not.toHaveBeenCalled()
  })

  it('sets taskCreating true while working and false after success', async () => {
    let resolveMcp: (value: string) => void
    mockCallMcpToolAtIdentity.mockImplementation(() => new Promise<string>((r) => { resolveMcp = r }))
    const promise = createTask({ title: 't', description: '' })
    await new Promise<void>((r) => setTimeout(() => r(), 5))
    expect(taskCreating.value).toBe(true)
    resolveMcp!(created(firstCallArgs()))
    await promise
    expect(taskCreating.value).toBe(false)
  })

  it('shows success and finishes the current presentation', async () => {
    const finish = vi.fn(() => true)
    await createTask({ title: 't', description: '' }, undefined, { finish })
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
    expect(finish).toHaveBeenCalledOnce()
  })

  it('does not announce or refresh a new workspace if finishing the old draft retires its owner', async () => {
    const finish = vi.fn(() => {
      mockAuthority.peek.mockReturnValue({ epoch: 'epoch-b', workspaceRoot: '/b', connectionGeneration: 1 })
      return true
    })
    expect(await createTask({ title: 't', description: '' }, undefined, { finish })).toBe(true)
    expect(mockShowToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
    expect(mockRefreshExecution).not.toHaveBeenCalled()
    expect(mockRefreshGoals).not.toHaveBeenCalled()
  })

  it('refreshes the Task observation on goalless success', async () => {
    await createTask({ title: 't', description: '' })
    expect(mockRefreshExecution).toHaveBeenCalledWith({ force: true })
    expect(mockRefreshGoals).not.toHaveBeenCalled()
  })

  it('reports an uncertain outcome rather than claiming the write failed', async () => {
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('network down'))
    const result = await createTask({ title: 't', description: '' })
    expect(result).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('결과를 확인할 수 없습니다'), 'warning')
    expect(showTaskCreate.value).toBe(false)
  })

  it('does not expose a raw non-Error transport failure', async () => {
    mockCallMcpToolAtIdentity.mockRejectedValueOnce('weird')
    await createTask({ title: 't', description: '' })
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('결과를 확인할 수 없습니다'), 'warning')
  })

  it('always resets taskCreating even on failure', async () => {
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('fail'))
    await createTask({ title: 't', description: '' })
    expect(taskCreating.value).toBe(false)
  })
  it('preserves successful creation when only the following observation refresh fails', async () => {
    showTaskCreate.value = true
    mockRefreshExecution.mockRejectedValueOnce(new Error('observation unavailable'))
    const result = await createTask({ title: 'created once', description: '' })
    expect(result).toBe(true)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
    expect(mockShowToast).not.toHaveBeenCalledWith(expect.stringContaining('생성 실패'), 'error')
    expect(showTaskCreate.value).toBe(true)
    expect(taskCreating.value).toBe(false)
  })

  it('binds an assignment to the observed workspace and retains success when refresh fails', async () => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true, isOwnerCurrent: () => true,
      refreshAfterWrite: vi.fn(() => true) }
    mockRefreshExecution.mockRejectedValueOnce(new Error('observation unavailable'))
    mockCallMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, task_id: 'task-1', goal_id: 'goal-1' }))
    expect(await assignTaskToGoal('task-1', 'goal-1', dispatch)).toBe(true)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledWith('masc_task_set_goal', {
      task_id: 'task-1', goal_id: 'goal-1', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' },
    }, dispatch.identity, dispatch.isCurrent, undefined, undefined)
    expect(dispatch.refreshAfterWrite).toHaveBeenCalledOnce()
    expect(mockShowToast).toHaveBeenCalledWith('목표에 배정 완료', 'success')
  })

  it.each([
    ['known_pre_effect', '배정 전에 요청이 거부'],
    ['known_tool_response', '서버가 배정 오류를 반환'],
    ['outcome_unknown', '배정 결과를 확인할 수 없습니다'],
  ])('distinguishes a %s assignment outcome without exposing raw errors', async (disposition, expected) => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true, isOwnerCurrent: () => true,
      refreshAfterWrite: vi.fn(() => true) }
    mockFailureDisposition.mockReturnValue(disposition)
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('private error'))
    expect(await assignTaskToGoal('task-1', 'goal-1', dispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining(expected), 'warning')
    expect(dispatch.refreshAfterWrite).toHaveBeenCalledTimes(disposition === 'known_pre_effect' ? 0 : 1)
    expect(JSON.stringify(mockShowToast.mock.calls)).not.toContain('private error')
  })

  it('does not refresh the new owner after an earlier assignment completes', async () => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true, isOwnerCurrent: () => false,
      refreshAfterWrite: vi.fn(() => false) }
    mockCallMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, task_id: 'task-1', goal_id: 'goal-1' }))
    expect(await assignTaskToGoal('task-1', 'goal-1', dispatch)).toBe(true)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('이전 관측'), 'warning')
    expect(mockRefreshExecution).not.toHaveBeenCalled()
    expect(mockRefreshGoals).not.toHaveBeenCalled()
    expect(dispatch.refreshAfterWrite).toHaveBeenCalledOnce()
  })

  it('refreshes the same owner after the Task observation changes during assignment', async () => {
    let current = true
    let resolveWrite!: (value: string) => void
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => current, isOwnerCurrent: () => true,
      refreshAfterWrite: vi.fn(() => true) }
    mockCallMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveWrite = resolve }))
    const result = assignTaskToGoal('task-1', 'goal-1', dispatch)
    current = false
    resolveWrite(JSON.stringify({ ok: true, task_id: 'task-1', goal_id: 'goal-1' }))
    expect(await result).toBe(true)
    expect(mockRefreshExecution).toHaveBeenCalledWith({ force: true })
    expect(dispatch.refreshAfterWrite).toHaveBeenCalledOnce()
    expect(mockRefreshGoals).not.toHaveBeenCalled()
    expect(mockShowToast).toHaveBeenCalledWith('목표에 배정 완료', 'success')
  })

  it.each(['', '{}', '{"ok":true,"task_id":"other","goal_id":"goal-1"}'])
  ('treats an absent or mismatched assignment receipt as an unknown outcome', async response => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true, isOwnerCurrent: () => true,
      refreshAfterWrite: vi.fn(() => true) }
    mockCallMcpToolAtIdentity.mockResolvedValueOnce(response)
    expect(await assignTaskToGoal('task-1', 'goal-1', dispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('배정 결과를 확인할 수 없습니다'), 'warning')
    expect(dispatch.refreshAfterWrite).toHaveBeenCalledOnce()
    expect(mockRefreshExecution).not.toHaveBeenCalled()
  })

})
