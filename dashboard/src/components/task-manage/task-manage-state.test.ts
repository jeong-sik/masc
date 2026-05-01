// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { showTaskCreate, taskCreating, createTask } from './task-manage-state'

const mockCallMcpTool = vi.fn()
const mockShowToast = vi.fn()
const mockRefreshExecution = vi.fn()
const mockRefreshGoals = vi.fn()

vi.mock('../../api/mcp', () => ({ callMcpTool: (...args: any[]) => mockCallMcpTool(...args) }))
vi.mock('../common/toast', () => ({ showToast: (...args: any[]) => mockShowToast(...args) }))
vi.mock('../../store', () => ({
  refreshExecution: (...args: any[]) => mockRefreshExecution(...args),
  refreshGoals: () => mockRefreshGoals(),
}))

const flushAsync = () => new Promise<void>((r) => setTimeout(() => r(), 10))

describe('task-manage-state', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    taskCreating.value = false
    mockCallMcpTool.mockReset()
    mockShowToast.mockReset()
    mockRefreshExecution.mockReset()
    mockRefreshGoals.mockReset()
    mockCallMcpTool.mockResolvedValue(undefined)
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

  it('createTask includes goal_id when provided and trimmed', async () => {
    await createTask({ title: 't', description: '', goal_id: '  g-123  ' })
    expect(mockCallMcpTool).toHaveBeenCalledWith('masc_add_task', expect.objectContaining({ goal_id: 'g-123' }))
  })

  it('createTask omits goal_id when empty', async () => {
    await createTask({ title: 't', description: '', goal_id: '' })
    const args = mockCallMcpTool.mock.calls[0]![1] as Record<string, unknown>
    expect(args.goal_id).toBeUndefined()
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

  it('shows success toast and closes form on success', async () => {
    await createTask({ title: 't', description: '' })
    expect(mockShowToast).toHaveBeenCalledWith('태스크 생성 완료', 'success')
    expect(showTaskCreate.value).toBe(false)
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
})
