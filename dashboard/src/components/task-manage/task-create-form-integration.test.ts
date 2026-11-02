// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  callMcpToolAtIdentity: vi.fn(),
  failureDisposition: vi.fn(),
  captureWorkspace: vi.fn(),
  authority: { peek: vi.fn() },
  workspaceRevision: { peek: vi.fn() },
  executionError: { peek: vi.fn() },
  tasks: { peek: vi.fn() },
  showToast: vi.fn(),
  refreshExecution: vi.fn(),
  refreshGoals: vi.fn(),
  fetchScopedGoals: vi.fn(),
  lastGoalsRefreshAt: { peek: vi.fn() },
  refreshShell: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpToolAtIdentity: mocks.callMcpToolAtIdentity,
  callMcpTaskCreationAtIdentity: (args: unknown, identity: unknown, current: unknown, recovery: unknown, wait: unknown) =>
    mocks.callMcpToolAtIdentity('masc_add_task', args, identity, current, recovery, wait),
  mcpCallFailureDisposition: mocks.failureDisposition,
}))
vi.mock('../../api/published-artifacts', () => ({
  captureArtifactWorkspace: mocks.captureWorkspace,
  artifactWorkspaceBody: (workspace: { basePath: string; mascRoot: string }) =>
    ({ base_path: workspace.basePath, masc_root: workspace.mascRoot }),
}))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../../store', () => ({ executionWorkspaceAuthority: mocks.authority, executionWorkspaceRevision: mocks.workspaceRevision,
  executionError: mocks.executionError, tasks: mocks.tasks, lastGoalsRefreshAt: mocks.lastGoalsRefreshAt,
  refreshExecution: mocks.refreshExecution, refreshGoals: mocks.refreshGoals, refreshShell: mocks.refreshShell }))
vi.mock('../../api/dashboard-goals', async () => ({
  ...await vi.importActual<typeof import('../../api/dashboard-goals')>('../../api/dashboard-goals'),
  fetchDashboardGoalsTree: mocks.fetchScopedGoals,
}))

import { TaskCreateForm, resetForm } from './task-create-form'
import { TaskCreateReceiptsPanel } from './task-create-receipt-panel'
import { _testResetTaskCreateState, createTask, showTaskCreate, taskCreateReceipts, taskCreating } from './task-manage-state'
import { clearStoredToken, currentDashboardActor, currentStoredTokenRevision, setStoredToken } from '../../api/core'
import { goalTreeData, goalTreeError, goalTreeLoading, goalTreeObservationRevision } from '../../goal-tree-state'
import type { DashboardGoalsTreeResponse } from '../../types'

function created(args: Record<string, unknown>): string {
  return JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
    goal_id: args.goal_id ?? null, task_id: 'task-1' })
}

function identity() { return { revision: currentStoredTokenRevision(), actor: currentDashboardActor() } }

function goalTree(goalId: string, taskId = 'task-1', taskGoalId = goalId): DashboardGoalsTreeResponse {
  return { tree: [{ id: goalId, tasks: [{ id: taskId, goal_id: taskGoalId }], children: [] }],
    summary: {}, identity_observation: { ids: [goalId], complete: true } } as unknown as DashboardGoalsTreeResponse
}

function callArgs(index: number): Record<string, unknown> {
  const args: unknown = mocks.callMcpToolAtIdentity.mock.calls[index]?.[1]
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error(`Missing MCP call arguments at ${index}`)
  return args as Record<string, unknown>
}

function requiredAt<T>(items: readonly T[], index: number): T {
  const value = items[index]
  if (value === undefined) throw new Error(`Missing item at ${index}`)
  return value
}

function inputDraft(title: string, description: string, priority: string) {
  const titleInput = screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement
  const descriptionInput = screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement
  const priorityInput = screen.getByRole('combobox') as HTMLSelectElement
  fireEvent.input(titleInput, { target: { value: title } })
  fireEvent.input(descriptionInput, { target: { value: description } })
  priorityInput.value = priority
  fireEvent(priorityInput, new Event('change', { bubbles: true }))
}

describe('Task creation draft ownership', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    resetForm()
    vi.resetAllMocks()
    clearStoredToken()
    _testResetTaskCreateState()
    mocks.authority.peek.mockReturnValue({ epoch: 'epoch-a', workspaceRoot: '/a', connectionGeneration: 1 })
    mocks.workspaceRevision.peek.mockReturnValue(1)
    mocks.executionError.peek.mockReturnValue(null)
    mocks.tasks.peek.mockReturnValue([{ id: 'task-1' }])
    mocks.lastGoalsRefreshAt.peek.mockReturnValue('2026-11-02T00:00:00.000Z')
    goalTreeData.value = null
    goalTreeError.value = null
    goalTreeLoading.value = false
    goalTreeObservationRevision.value = 0
    mocks.captureWorkspace.mockResolvedValue({ basePath: '/a', mascRoot: '/a/.masc' })
    mocks.refreshExecution.mockResolvedValue(undefined)
    mocks.refreshGoals.mockImplementation(async () => {
      const goalId = callArgs(0).goal_id
      if (typeof goalId === 'string') goalTreeData.value = goalTree(goalId)
      goalTreeObservationRevision.value++
    })
    mocks.fetchScopedGoals.mockImplementation(async () => goalTreeData.peek())
    mocks.refreshShell.mockResolvedValue(true)
    mocks.failureDisposition.mockReturnValue('outcome_unknown')
    mocks.callMcpToolAtIdentity.mockImplementation(async (_name: string, args: Record<string, unknown>) => created(args))
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    clearStoredToken()
    showTaskCreate.value = false
    resetForm()
  })

  it('finishes the submitted draft after a successful current request', async () => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Submitted task', 'Submitted detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))

    await waitFor(() => expect(showTaskCreate.value).toBe(false))
    await waitFor(() => expect(taskCreateReceipts.attempts.value).toHaveLength(0))
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('3')
  })

  it('automatically removes a nested Goal Task only after current and scoped trees both observe it', async () => {
    const nested = { tree: [{ id: 'parent', tasks: [], children: goalTree('goal-a').tree }], summary: {},
      identity_observation: { ids: ['parent', 'goal-a'], complete: true } } as unknown as DashboardGoalsTreeResponse
    mocks.refreshGoals.mockImplementation(async () => { goalTreeData.value = nested; goalTreeObservationRevision.value++ })
    mocks.fetchScopedGoals.mockResolvedValue(nested)
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' }, identity: identity(), isCurrent: () => true }
    expect(await createTask({ title: 't', description: '', goal_id: 'goal-a' }, dispatch)).toBe(true)
    expect(mocks.fetchScopedGoals).toHaveBeenCalledWith(dispatch.workspace)
    expect(taskCreateReceipts.attempts.peek()).toHaveLength(0)
  })

  it.each(['partial error', 'superseded', 'missing task', 'wrong goal', 'duplicate goal', 'direct error', 'direct mismatch'])(
    'retains the created receipt when Goal observation is %s', async condition => {
      const valid = goalTree('goal-a')
      goalTreeData.value = valid
      mocks.refreshGoals.mockImplementation(async () => {
        if (condition === 'superseded') return
        goalTreeObservationRevision.value++
        if (condition === 'partial error') { goalTreeData.value = null; goalTreeError.value = 'goal tree unavailable'; return }
        if (condition === 'missing task') goalTreeData.value = goalTree('goal-a', 'another-task')
        else if (condition === 'wrong goal') goalTreeData.value = goalTree('goal-a', 'task-1', 'another-goal')
        else if (condition === 'duplicate goal') {
          goalTreeData.value = { ...valid, identity_observation: { ids: ['goal-a', 'goal-a'], complete: true } }
        } else goalTreeData.value = valid
      })
      if (condition === 'direct error') mocks.fetchScopedGoals.mockRejectedValueOnce(new Error('direct read unavailable'))
      if (condition === 'direct mismatch') mocks.fetchScopedGoals.mockResolvedValueOnce(goalTree('another-goal'))
      vi.spyOn(console, 'warn').mockImplementation(() => {})
      const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' }, identity: identity(), isCurrent: () => true }
      expect(await createTask({ title: 't', description: '', goal_id: 'goal-a' }, dispatch)).toBe(true)
      expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-1' },
        presented: false })
      expect(mocks.showToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
    },
  )

  it('does not automatically remove a Goal receipt when ownership changes during the scoped read', async () => {
    let finishTree!: (tree: DashboardGoalsTreeResponse) => void
    mocks.fetchScopedGoals.mockImplementationOnce(() => new Promise(resolve => { finishTree = resolve }))
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' }, identity: identity(), isCurrent: () => true }
    const pending = createTask({ title: 't', description: '', goal_id: 'goal-a' }, dispatch)
    await waitFor(() => expect(mocks.fetchScopedGoals).toHaveBeenCalledOnce())
    setStoredToken('different-credential', { source: 'manual' })
    finishTree(goalTree('goal-a'))
    expect(await pending).toBe(true)
    expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-1' },
      presented: false, originalCurrent: false })
  })

  it('shows the Task ID and retains a confirmed receipt when post-write refresh fails', async () => {
    mocks.refreshExecution.mockRejectedValueOnce(new Error('refresh unavailable'))
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Created task', 'Detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    await waitFor(() => expect(mocks.refreshExecution).toHaveBeenCalledOnce())
    expect(mocks.showToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
    expect(taskCreateReceipts.attempts.value[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-1' }, presented: false })
    expect(mocks.callMcpToolAtIdentity.mock.calls.filter(call => call[0] === 'masc_add_task')).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: '이 결과 확인' }))
    await waitFor(() => expect(screen.queryByRole('region', { name: '이전 태스크 생성 요청' })).toBeNull())
  })

  it.each(['missing task', 'store error'])('keeps the receipt when refresh resolves with %s', async condition => {
    if (condition === 'missing task') mocks.tasks.peek.mockReturnValue([])
    else mocks.executionError.peek.mockReturnValue('projection unavailable')
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Created task', 'Detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    await waitFor(() => expect(mocks.refreshExecution).toHaveBeenCalledOnce())
    expect(taskCreateReceipts.attempts.value[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-1' }, presented: false })
    expect(mocks.showToast).toHaveBeenCalledWith('태스크 생성 완료 · task-1', 'success')
  })

  it('keeps the new Goal draft when an earlier Goal creation succeeds late', async () => {
    let resolveCreate!: (value: string) => void
    let firstIsCurrent = true
    const first = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => firstIsCurrent }
    const second = { ...first, isCurrent: () => true }
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    const view = render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${first} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    firstIsCurrent = false
    view.rerender(html`<${TaskCreateForm} goalId="goal-b" goalDispatch=${second} />`)
    inputDraft('New draft', 'New detail', '2')
    resolveCreate(created(callArgs(0)))
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('New draft')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('New detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('2')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })

  it('keeps a reopened draft even when the original Goal is still current', async () => {
    let resolveCreate!: (value: string) => void
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Same text', 'Same detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    fireEvent.click(screen.getByRole('button', { name: '취소' }))
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Same text', 'Same detail', '1')
    resolveCreate(created(callArgs(0)))
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Same text')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('Same detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('1')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })

  it('keeps the shared draft after navigating from Planning to a Goal', async () => {
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    const planning = render(html`<${TaskCreateForm} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Planning task', 'Planning detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    planning.unmount()
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Planning task')
    resolveCreate(created(callArgs(0)))
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Planning task')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('Planning detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('1')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })

  it('keeps a Planning draft open when its earlier workspace creation succeeds', async () => {
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    render(html`<${TaskCreateForm} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Workspace A task', 'Original detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    mocks.authority.peek.mockReturnValue({ epoch: 'epoch-b', workspaceRoot: '/b', connectionGeneration: 1 })
    resolveCreate(created(callArgs(0)))
    await waitFor(() => expect(taskCreating.value).toBe(false))
    expect(showTaskCreate.value).toBe(true)
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Workspace A task')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('Original detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('2')
    expect(mocks.showToast).not.toHaveBeenCalledWith(expect.stringContaining('태스크 생성 완료'), 'success')
    expect(mocks.refreshExecution).not.toHaveBeenCalled()
    expect(mocks.refreshGoals).not.toHaveBeenCalled()
  })

  it('does not send a cancelled Planning draft after the workspace read completes', async () => {
    let resolveWorkspace!: (workspace: { basePath: string; mascRoot: string }) => void
    mocks.captureWorkspace.mockImplementationOnce(() => new Promise(resolve => { resolveWorkspace = resolve }))
    render(html`<${TaskCreateForm} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('First draft', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.captureWorkspace).toHaveBeenCalledOnce())
    fireEvent.click(screen.getByRole('button', { name: '취소' }))
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('New draft', 'New detail', '2')
    resolveWorkspace({ basePath: '/a', mascRoot: '/a/.masc' })
    await waitFor(() => expect(taskCreating.value).toBe(false))
    expect(mocks.callMcpToolAtIdentity).not.toHaveBeenCalled()
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('New draft')
    expect(showTaskCreate.value).toBe(true)
  })

  it('keeps the second draft pending when a separate first request succeeds', async () => {
    const resolvers: Array<(value: string) => void> = []
    mocks.callMcpToolAtIdentity.mockImplementation(() => new Promise<string>(resolve => { resolvers.push(resolve) }))
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: identity(), isCurrent: () => true }
    render(html`<div><${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(resolvers).toHaveLength(1))
    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    inputDraft('Second request', 'Second detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(resolvers).toHaveLength(2))
    const firstArgs = callArgs(0)
    const secondArgs = callArgs(1)
    expect(firstArgs.creation_request_id).not.toBe(secondArgs.creation_request_id)

    requiredAt(resolvers, 0)(created(firstArgs))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    expect(taskCreating.value).toBe(true)
    expect(screen.getByRole('button', { name: '추가 중...' }).hasAttribute('disabled')).toBe(true)
    expect(taskCreateReceipts.attempts.value.find(item => item.requestId === secondArgs.creation_request_id)?.original)
      .toEqual({ kind: 'pending' })
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Second request')

    requiredAt(resolvers, 1)(created(secondArgs))
    await waitFor(() => expect(taskCreating.value).toBe(false))
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledTimes(2)
  })

  it('restores a late success and its Goal identity after reload until the user sees it', async () => {
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' }, identity: identity(), isCurrent: () => true }
    const view = render(html`<div><${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())
    const args = callArgs(0)
    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    inputDraft('New draft', 'New detail', '2')
    resolveCreate(created(args))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    expect(taskCreateReceipts.attempts.value[0]?.presented).toBe(false)

    view.unmount()
    _testResetTaskCreateState({ preserveStorage: true })
    const restored = render(html`<${TaskCreateReceiptsPanel} />`)
    expect(screen.queryByText(new RegExp(String(args.creation_request_id)))).toBeNull()
    expect(screen.getByText(/이전 요청이 있습니다/)).toBeTruthy()
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-1'] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    expect(screen.getByText(new RegExp(String(args.creation_request_id)))).toBeTruthy()
    expect(screen.getByText(/Goal goal-a/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: '이 결과 확인' }))
    await waitFor(() => expect(taskCreateReceipts.attempts.value[0]?.presented).toBe(true))
    restored.unmount()
    _testResetTaskCreateState({ preserveStorage: true })
    render(html`<${TaskCreateReceiptsPanel} />`)
    expect(screen.queryByText(/task-1|goal-a/)).toBeNull()
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-1'] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    fireEvent.click(screen.getByRole('button', { name: '확인된 기록과 반복 조회 정리' }))
    await waitFor(() => expect(screen.queryByRole('region', { name: '이전 태스크 생성 요청' })).toBeNull())
  })

  it('allows a restored definite refusal to be authenticated and removed', async () => {
    mocks.failureDisposition.mockReturnValue('known_pre_effect')
    mocks.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('refused before dispatch'))
    vi.spyOn(taskCreateReceipts, 'forgetDefinite').mockReturnValue(false)
    const view = render(html`<${TaskCreateForm} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Refused task', 'Detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('생성 전에'), 'warning'))
    const args = callArgs(0)
    view.unmount()
    _testResetTaskCreateState({ preserveStorage: true })
    render(html`<${TaskCreateReceiptsPanel} />`)
    expect(screen.queryByText(new RegExp(String(args.creation_request_id)))).toBeNull()
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'not_observed', task_ids: [] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText('태스크 생성 전에 요청이 거부되었습니다.')
    fireEvent.click(screen.getByRole('button', { name: '확인된 기록과 반복 조회 정리' }))
    await waitFor(() => expect(screen.queryByRole('region', { name: '이전 태스크 생성 요청' })).toBeNull())
    expect(mocks.callMcpToolAtIdentity.mock.calls.filter(call => call[0] === 'masc_add_task')).toHaveLength(1)
  })

  it('keeps an ambiguous read visible after a late success is acknowledged', async () => {
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())
    const args = callArgs(0)
    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    resolveCreate(created(args))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'ambiguous', task_ids: ['task-1', 'task-2'] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/생성 기록이 여러 건입니다/)
    fireEvent.click(screen.getByRole('button', { name: '이 결과 확인' }))
    expect(screen.getByText(/생성 기록이 여러 건입니다/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: '이 결과 확인' })).toBeNull()
    expect(mocks.callMcpToolAtIdentity.mock.calls.filter(call => call[0] === 'masc_add_task')).toHaveLength(1)
  })

  it.each(['401', '403', 'invalid'])('does not reveal restored evidence to another credential after %s', async (failure) => {
    setStoredToken('actor-a-token', { source: 'manual' })
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' }, identity: identity(), isCurrent: () => true }
    const view = render(html`<div><${TaskCreateForm} goalId="goal-private" goalDispatch=${dispatch} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Private request', 'Private detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())
    const args = callArgs(0)
    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    resolveCreate(created(args))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'ambiguous', task_ids: ['task-1', 'task-2'] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/task-2/)
    view.unmount()

    setStoredToken('actor-b-token', { source: 'manual' })
    _testResetTaskCreateState({ preserveStorage: true })
    render(html`<${TaskCreateReceiptsPanel} />`)
    const assertHidden = () => {
      expect(screen.queryByText(/task-1|task-2|goal-private/)).toBeNull()
      expect(screen.queryByText(new RegExp(String(args.creation_request_id)))).toBeNull()
      expect(screen.queryByRole('button', { name: '이 결과 확인' })).toBeNull()
    }
    assertHidden()
    if (failure === 'invalid') {
      mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: 'another',
        workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
        creation_receipt: { state: 'recorded', task_ids: ['task-1'] } }))
    } else mocks.callMcpToolAtIdentity.mockRejectedValueOnce(new Error(`HTTP ${failure}`))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/생성 기록을 확인하지 못했습니다/)
    assertHidden()
    fireEvent.click(screen.getByRole('button', { name: '확인된 기록과 반복 조회 정리' }))
    expect(taskCreateReceipts.attempts.value).toHaveLength(1)
    assertHidden()

    setStoredToken('actor-a-token', { source: 'manual' })
    await waitFor(() => expect(screen.queryByText(/생성 기록을 확인하지 못했습니다/)).toBeNull())
    assertHidden()
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-1'] } }))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    expect(screen.getByText(/Goal goal-private/)).toBeTruthy()
    expect(mocks.callMcpToolAtIdentity.mock.calls.filter(call => call[0] === 'masc_add_task')).toHaveLength(1)
  })

  it('withdraws previously visible evidence when the same credential is refused a later read', async () => {
    let resolveCreate!: (value: string) => void
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<string>(resolve => { resolveCreate = resolve }))
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())
    const args = callArgs(0)
    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    resolveCreate(created(args))
    await screen.findByText('task-1 생성 응답을 받았습니다.')
    mocks.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('HTTP 403'))
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/생성 기록을 확인하지 못했습니다/)
    expect(screen.queryByText(/task-1/)).toBeNull()
    expect(screen.queryByText(new RegExp(String(args.creation_request_id)))).toBeNull()
    expect(screen.queryByRole('button', { name: '이 결과 확인' })).toBeNull()
    expect(taskCreateReceipts.attempts.value[0]).toMatchObject({ originalCurrent: true,
      latestReadCurrent: false, latestReadFailureCurrent: true })
  })

  it('checks an uncertain request without replaying it and requires a separate draft for another Task', async () => {
    let creationCalls = 0
    let reads = 0
    mocks.callMcpToolAtIdentity.mockImplementation(async (name: string, args: Record<string, unknown>) => {
      if (name === 'masc_add_task') {
        creationCalls++
        if (creationCalls === 1) throw new Error('connection lost')
        return created(args)
      }
      expect(name).toBe('masc_tasks')
      reads++
      return JSON.stringify({ ok: true, creation_request_id: args.creation_request_id,
        workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: reads,
        creation_receipt: reads === 1 ? { state: 'not_observed', task_ids: [] }
          : { state: 'recorded', task_ids: ['task-original'] } })
    })
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Original task', 'Original detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await screen.findByText(/태스크 생성 결과가 미확인입니다/)
    const originalId = callArgs(0).creation_request_id
    expect(screen.getByRole('button', { name: 'backlog에 추가' }).hasAttribute('disabled')).toBe(true)

    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/아직 생성 기록을 찾지 못했습니다/)
    expect(screen.getByRole('button', { name: 'backlog에 추가' }).hasAttribute('disabled')).toBe(true)
    expect(creationCalls).toBe(1)
    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    await screen.findByText(/task-original의 생성 기록을 확인했습니다/)
    expect(screen.getByText(/현재 상태나 완료를 뜻하지는 않습니다/)).toBeTruthy()
    const original = taskCreateReceipts.attempts.value.find(item => item.requestId === originalId)!
    expect(original.original).toEqual({ kind: 'unconfirmed', reason: 'response_unknown' })
    expect(original.reads.map(read => read.kind)).toEqual(['not_observed', 'recorded'])
    expect(creationCalls).toBe(1)

    fireEvent.click(screen.getByRole('button', { name: '별도 새 태스크 작성' }))
    inputDraft('Separate task', 'Separate detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(creationCalls).toBe(2))
    const newId = callArgs(3).creation_request_id
    expect(newId).not.toBe(originalId)
    expect(taskCreateReceipts.attempts.value.find(item => item.requestId === originalId)?.reads).toHaveLength(2)
  })

  it('requires an explicit memory-only choice after storage fails and never submits from that choice', async () => {
    vi.stubGlobal('sessionStorage', {
      getItem: () => null,
      setItem: () => { throw new Error('storage blocked') },
      removeItem: () => {},
    })
    _testResetTaskCreateState()
    mocks.tasks.peek.mockReturnValue([])
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Memory only task', 'Private detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await screen.findByText(/요청 기록을 저장할 수 없습니다/)
    expect(mocks.callMcpToolAtIdentity).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '이번 초안은 메모리에만 보관' }))
    await screen.findByText(/이번 요청은 이 탭의 메모리에만 보관됩니다/)
    expect(mocks.callMcpToolAtIdentity).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())
    expect(taskCreateReceipts.attempts.value[0]?.persistence).toBe('memory')
  })

  it('allows the same draft to be retried after a proven pre-effect refusal', async () => {
    mocks.failureDisposition.mockReturnValue('known_pre_effect')
    mocks.callMcpToolAtIdentity.mockRejectedValueOnce(new Error('refused before dispatch'))
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    inputDraft('Refused task', 'Still editable', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('생성 전에'), 'warning'))
    expect(screen.queryByRole('button', { name: '별도 새 태스크 작성' })).toBeNull()
    expect(screen.queryByRole('region', { name: '이전 태스크 생성 요청' })).toBeNull()
    expect(screen.getByRole('button', { name: 'backlog에 추가' }).hasAttribute('disabled')).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledTimes(2))
    expect(callArgs(0).creation_request_id)
      .not.toBe(callArgs(1).creation_request_id)
  })
})
