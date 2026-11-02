// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ fetchExecution: vi.fn(), showToast: vi.fn() }))
vi.mock('../../api/dashboard-execution', () => ({ fetchDashboardExecution: mocks.fetchExecution }))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: async () => {} }))

import { clearStoredToken, currentDashboardActor, currentStoredTokenRevision, setStoredToken } from '../../api/core'
import { resetMcpClientState } from '../../api/mcp'
import { DASHBOARD_AGENT_NAME_KEY, persistDashboardActorName } from '../../lib/dashboard-actor'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import * as store from '../../store'
import { goalTreeData, goalTreeError } from '../../goal-tree-state'
import { TaskCreateForm, resetForm } from './task-create-form'
import { TaskCreateReceiptsPanel } from './task-create-receipt-panel'
import { _testResetTaskCreateState, createTask, showTaskCreate, taskCreateReceiptOwner, taskCreateReceipts } from './task-manage-state'

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })
}

beforeEach(() => {
  vi.resetAllMocks()
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  clearStoredToken()
  resetDashboardSessionActorForTests()
  resetMcpClientState()
  _testResetTaskCreateState()
  showTaskCreate.value = false
  resetForm()
  expect(store.hydrateExecutionSnapshot({
    execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
    status: { project: 'project-a', workspace_root: '/a' }, agents: [], tasks: [], messages: [], keepers: [],
  })).toBe(true)
  mocks.fetchExecution.mockRejectedValue(Object.assign(new Error('execution unavailable'), { status: 503 }))
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  clearStoredToken()
  resetDashboardSessionActorForTests()
  window.localStorage.removeItem(DASHBOARD_AGENT_NAME_KEY)
})

it.each(['recorded', 'denied', 'workspace-mismatch', 'workspace-change-after', 'workspace-aba', 'token-aba', 'actor-aba', 'managed-hint'])(
  'uses only a scoped read after real execution authority withdrawal: %s', async scenario => {
    setStoredToken('actor-a-token', scenario === 'managed-hint'
      ? { source: 'dev', actor: 'dashboard', role: 'admin' } : { source: 'manual' })
    let resolveRead!: (response: Response) => void
    let readRpcId = ''
    let creationRequestId = ''
    let taskPosts = 0
    let receiptReads = 0
    let healthReads = 0
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/health?full=1') {
        healthReads++
        return json({ paths: ((scenario === 'workspace-mismatch' && healthReads > 1)
          || (scenario === 'workspace-change-after' && healthReads > 2))
          ? { effective_base_path: '/b', effective_masc_root: '/b/.masc' }
          : { effective_base_path: '/a', effective_masc_root: '/a/.masc' } })
      }
      expect(url).toBe('/mcp')
      const request = JSON.parse(String(init?.body))
      if (request.params.name === 'masc_add_task') {
        taskPosts++
        creationRequestId = request.params.arguments.creation_request_id
        const text = JSON.stringify({ ok: true, creation_request_id: creationRequestId, goal_id: null, task_id: 'task-private' })
        return json({ id: request.id, result: { content: [{ type: 'text', text }] } })
      }
      expect(request.params.name).toBe('masc_tasks')
      expect(request.params.arguments).toMatchObject({ creation_request_id: creationRequestId,
        expected_workspace: { base_path: '/a', masc_root: '/a/.masc' } })
      receiptReads++
      readRpcId = request.id
      return new Promise<Response>(resolve => { resolveRead = resolve })
    })
    vi.stubGlobal('fetch', fetchMock)
    render(html`<div><${TaskCreateForm} /><${TaskCreateReceiptsPanel} /></div>`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    fireEvent.input(screen.getByPlaceholderText('예: runtime config introspection 정리'), { target: { value: 'first task' } })
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.fetchExecution).toHaveBeenCalledOnce())
    await waitFor(() => expect(store.executionWorkspaceAuthority.peek()).toBeNull())
    expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-private' })
    expect(screen.queryByText(/task-private/)).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
    if (scenario === 'workspace-mismatch') {
      await waitFor(() => expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('작업 공간을 확인하지 못했습니다'), 'warning'))
      expect(receiptReads).toBe(0)
      expect(taskCreateReceiptOwner.peek()).toBeNull()
      expect(screen.queryByText(/task-private/)).toBeNull()
      expect(await createTask({ title: 'another', description: '' })).toBe(false)
      expect(taskPosts).toBe(1)
      return
    }
    await waitFor(() => expect(receiptReads).toBe(1))
    expect(taskCreateReceiptOwner.peek()?.access).toBe('read_only')
    expect(taskCreateReceipts.reserve()).toEqual({ kind: 'owner_unavailable' })
    expect(taskCreateReceipts.reserveMemoryOnly()).toEqual({ kind: 'owner_unavailable' })
    expect(screen.queryByText(/task-private/)).toBeNull()
    expect(screen.queryByText(new RegExp(creationRequestId))).toBeNull()
    if (scenario === 'workspace-aba') {
      store.executionWorkspaceRevision.value++
      store.executionWorkspaceRevision.value++
    } else if (scenario === 'token-aba') {
      setStoredToken('actor-b-token', { source: 'manual' })
      setStoredToken('actor-a-token', { source: 'manual' })
    } else if (scenario === 'actor-aba') {
      setCanonicalDashboardActor('other-actor')
      setCanonicalDashboardActor(null)
    } else if (scenario === 'managed-hint') {
      persistDashboardActorName('unused-hint')
    }
    const text = JSON.stringify({ ok: true, creation_request_id: creationRequestId,
      workspace: { base_path: '/a', masc_root: '/a/.masc' }, backlog_version: 5,
      creation_receipt: { state: 'recorded', task_ids: ['task-private'] } })
    resolveRead(scenario === 'denied' ? json({ error: 'denied' }, 403)
      : json({ id: readRpcId, result: { content: [{ type: 'text', text }] } }))
    if (scenario === 'recorded' || scenario === 'managed-hint' || scenario === 'workspace-change-after') {
      await screen.findByText('task-private 생성 응답을 받았습니다.')
      expect(taskCreateReceipts.attempts.peek()[0]?.latestReadCurrent).toBe(true)
      if (scenario === 'workspace-change-after') {
        fireEvent.click(screen.getByRole('button', { name: '결과 다시 확인' }))
        await waitFor(() => expect(taskCreateReceiptOwner.peek()).toBeNull())
        expect(screen.queryByText(/task-private/)).toBeNull()
        expect(taskCreateReceipts.attempts.peek()[0]?.original).toEqual({ kind: 'created', taskId: 'task-private' })
        expect(receiptReads).toBe(1)
      }
    } else if (scenario === 'denied') {
      await screen.findByText(/생성 기록을 확인하지 못했습니다/)
      expect(screen.queryByText(/task-private/)).toBeNull()
    } else {
      await waitFor(() => expect(taskCreateReceipts.attempts.peek()[0]?.checking).toBe(false))
      expect(taskCreateReceipts.attempts.peek()[0]?.reads).toEqual([])
      expect(screen.queryByText(/task-private/)).toBeNull()
    }
    expect(await createTask({ title: 'another', description: '' })).toBe(false)
    expect(taskPosts).toBe(1)
  },
)

it.each(['partial', 'attested', 'missing-attestation'])(
  'uses the real Goal refresh and direct workspace attestation before cleanup: %s', async scenario => {
    setStoredToken('actor-a-token', { source: 'manual' })
    mocks.fetchExecution.mockResolvedValue({
      execution_publication_epoch: 'recovery-fixture', execution_publication_generation: 1,
      status: { project: 'project-a', workspace_root: '/a' }, agents: [], messages: [], keepers: [],
      tasks: [{ id: 'task-private', title: 'Task', goal_id: 'goal-a', status: 'todo' }],
    })
    const tree = { approval_queue_state: { state: 'ready' }, tree: [{ id: 'goal-a', title: 'Goal', phase: 'executing',
      criterion_revision: 'criterion-1', measurement: { state: 'not_recorded' }, children: [],
      tasks: [{ id: 'task-private', title: 'Task', status: 'todo', goal_id: 'goal-a',
        is_terminal: false, created_at: '2026-01-01', updated_at: '2026-01-02' }] }],
    summary: { total_goals: 1, active_goals: 1, phase_counts: {}, total_tasks: 1, done_tasks: 0, pending_approvals: 0 } }
    let directReads = 0
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/api/v1/dashboard/planning') {
        return scenario === 'partial' ? json({ error: 'planning unavailable' }, 503)
          : json({ goals: [], rollup: { active_count: 0, verifying_count: 0, awaiting_confirmation_count: 0,
            done_count: 0, dropped_count: 0, paused_count: 0, blocked_count: 0 } })
      }
      if (url === '/api/v1/dashboard/goals') return json(tree)
      if (url.startsWith('/api/v1/dashboard/goals?')) {
        directReads++
        const headers = new Headers({ 'content-type': 'application/json' })
        if (scenario !== 'missing-attestation') {
          headers.set('x-masc-workspace-read', 'matched-v1')
          headers.set('x-masc-goal-tree-read', 'direct-v1')
        }
        return new Response(JSON.stringify(tree), { status: 200, headers })
      }
      expect(url).toBe('/mcp')
      const request = JSON.parse(String(init?.body))
      const text = JSON.stringify({ ok: true, creation_request_id: request.params.arguments.creation_request_id,
        goal_id: 'goal-a', task_id: 'task-private' })
      return json({ id: request.id, result: { content: [{ type: 'text', text }] } })
    })
    vi.stubGlobal('fetch', fetchMock)
    const authority = store.executionWorkspaceAuthority.peek()
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: currentStoredTokenRevision(), actor: currentDashboardActor() },
      isCurrent: () => store.executionWorkspaceAuthority.peek() === authority }
    expect(await createTask({ title: 't', description: '', goal_id: 'goal-a' }, dispatch)).toBe(true)
    if (scenario === 'partial') {
      expect(goalTreeData.peek()).toBeNull()
      expect(goalTreeError.peek()).not.toBeNull()
      expect(directReads).toBe(0)
    } else expect(directReads).toBe(1)
    if (scenario === 'attested') expect(taskCreateReceipts.attempts.peek()).toHaveLength(0)
    else expect(taskCreateReceipts.attempts.peek()[0]).toMatchObject({ original: { kind: 'created', taskId: 'task-private' },
      presented: false })
  },
)
