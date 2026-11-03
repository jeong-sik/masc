// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { showTaskCreate, taskCreating, createTask, assignTaskToGoal } from './task-manage-state'

const mockCallMcpTool = vi.fn()
const mockCallMcpToolAtIdentity = vi.fn()
const mockFailureDisposition = vi.fn<(error: unknown) => string>(() => 'outcome_unknown')
const mockShowToast = vi.fn()
const mockRefreshExecution = vi.fn()
const mockRefreshGoals = vi.fn()

vi.mock('../../api/mcp', () => ({ callMcpTool: (...args: any[]) => mockCallMcpTool(...args),
  callMcpToolAtIdentity: (...args: any[]) => mockCallMcpToolAtIdentity(...args),
  mcpCallFailureDisposition: (error: unknown) => mockFailureDisposition(error) }))
vi.mock('../common/toast', () => ({ showToast: (...args: any[]) => mockShowToast(...args) }))
vi.mock('../../store', () => ({
  refreshExecution: (...args: any[]) => mockRefreshExecution(...args),
  refreshGoals: () => mockRefreshGoals(),
}))


describe('task-manage-state', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    taskCreating.value = false
    mockCallMcpTool.mockReset()
    mockCallMcpToolAtIdentity.mockReset()
    mockFailureDisposition.mockReset().mockReturnValue('outcome_unknown')
    mockShowToast.mockReset()
    mockRefreshExecution.mockReset()
    mockRefreshGoals.mockReset()
    mockCallMcpTool.mockResolvedValue(undefined)
    mockCallMcpToolAtIdentity.mockResolvedValue(undefined)
    mockRefreshExecution.mockResolvedValue(undefined)
    mockRefreshGoals.mockResolvedValue(undefined)
  })

  afterEach(() => {
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
    expect(mockCallMcpTool).not.toHaveBeenCalled()
  })

  it('createTask calls masc_add_task with trimmed title and description', async () => {
    const result = await createTask({ title: '  my task  ', description: '  desc  ' })
    expect(mockCallMcpTool).toHaveBeenCalledOnce()
    expect(mockCallMcpTool).toHaveBeenCalledWith('masc_add_task', { title: 'my task', description: 'desc' })
    expect(result).toBe(true)
  })

  it('createTask includes priority when provided', async () => {
    await createTask({ title: 't', description: '', priority: 2 })
    expect(mockCallMcpTool).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({ priority: 2 }))
  })

  it('createTask preserves a canonical Goal ID and binds the observed workspace', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    await createTask({ title: 't', description: '', goal_id: '\u00a0g-123\u00a0' }, goalDispatch)
    expect(mockCallMcpToolAtIdentity).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({
      goal_id: '\u00a0g-123\u00a0', expected_workspace: { base_path: '/a', masc_root: '/a/.masc' },
    }), goalDispatch.identity, goalDispatch.isCurrent, undefined, undefined)
  })

  it('refuses blank, padded, or stale Goal targets instead of making an unlinked Task', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    for (const goal_id of ['', '  g-123  ']) {
      expect(await createTask({ title: 't', description: '', goal_id }, goalDispatch)).toBe(false)
    }
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' },
      { ...goalDispatch, isCurrent: () => false })).toBe(false)
    expect(mockCallMcpTool).not.toHaveBeenCalled()
    expect(mockCallMcpToolAtIdentity).not.toHaveBeenCalled()
  })

  it('keeps an uncertain Goal Task outcome distinct from a refusal', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
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
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    mockFailureDisposition.mockReturnValue(disposition)
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('private server detail'))
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining(message), 'warning')
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('workspace'), 'warning')
    expect(JSON.stringify(mockShowToast.mock.calls)).not.toContain('private server detail')
  })

  it('does not expose a late Goal Task error after the owner changes', async () => {
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: vi.fn().mockReturnValueOnce(true).mockReturnValue(false) }
    mockFailureDisposition.mockReturnValue('known_pre_effect')
    mockCallMcpToolAtIdentity.mockRejectedValueOnce(new Error('private server detail'))
    expect(await createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
    expect(JSON.stringify(mockShowToast.mock.calls)).not.toContain('private server detail')
  })

  it('does not present a late Goal Task creation as the current owner success', async () => {
    let current = true
    let resolveCreate!: () => void
    const goalDispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => current }
    mockCallMcpToolAtIdentity.mockImplementationOnce(() => new Promise<void>(resolve => { resolveCreate = resolve }))
    showTaskCreate.value = true
    const pending = createTask({ title: 't', description: '', goal_id: 'g-123' }, goalDispatch)
    current = false
    resolveCreate()
    expect(await pending).toBe(true)
    expect(showTaskCreate.value).toBe(true)
    expect(mockShowToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
    expect(mockShowToast).not.toHaveBeenCalledWith('태스크 생성 완료', 'success')
    expect(mockRefreshGoals).not.toHaveBeenCalled()
  })

  it('sets taskCreating true while working and false after success', async () => {
    let resolveMcp: () => void
    mockCallMcpTool.mockImplementation(() => new Promise<void>((r) => { resolveMcp = r }))
    const promise = createTask({ title: 't', description: '' })
    await new Promise<void>((r) => setTimeout(() => r(), 5))
    expect(taskCreating.value).toBe(true)
    resolveMcp!()
    await promise
    expect(taskCreating.value).toBe(false)
  })

  it('shows success and finishes the current presentation', async () => {
    const finish = vi.fn(() => true)
    await createTask({ title: 't', description: '' }, undefined, { finish })
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 완료', 'success')
    expect(finish).toHaveBeenCalledOnce()
  })

  it('refreshes execution and goals on success', async () => {
    await createTask({ title: 't', description: '' })
    expect(mockRefreshExecution).toHaveBeenCalledWith({ force: true })
    expect(mockRefreshGoals).toHaveBeenCalled()
  })

  it('shows error toast and returns false on MCP failure', async () => {
    mockCallMcpTool.mockRejectedValueOnce(new Error('network down'))
    const result = await createTask({ title: 't', description: '' })
    expect(result).toBe(false)
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 실패: network down', 'error')
    expect(showTaskCreate.value).toBe(false)
  })

  it('shows error toast for non-Error throws', async () => {
    mockCallMcpTool.mockRejectedValueOnce('weird')
    await createTask({ title: 't', description: '' })
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 실패: weird', 'error')
  })

  it('always resets taskCreating even on failure', async () => {
    mockCallMcpTool.mockRejectedValueOnce(new Error('fail'))
    await createTask({ title: 't', description: '' })
    expect(taskCreating.value).toBe(false)
  })
  it('preserves successful creation when only the following observation refresh fails', async () => {
    showTaskCreate.value = true
    mockRefreshExecution.mockRejectedValueOnce(new Error('observation unavailable'))
    const result = await createTask({ title: 'created once', description: '' })
    expect(result).toBe(true)
    expect(mockCallMcpTool).toHaveBeenCalledOnce()
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 완료', 'success')
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
    expect(mockCallMcpTool).not.toHaveBeenCalled()
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
