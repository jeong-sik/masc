import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardGoalDetailResponse,
  DashboardGoalsTreeResponse,
  GoalTreeNode,
} from '../../types'
import { hydrateGoalTreeError, hydrateGoalTreeSnapshot } from '../../goal-tree-state'

const mocks = vi.hoisted(() => ({
  fetchDashboardGoalDetail: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
  get: vi.fn(),
  callMcpTool: vi.fn(),
  callIdentity: vi.fn(),
  refreshExecution: vi.fn(),
  mcpCallFailureDisposition: vi.fn(() => 'known_tool_response'),
  mcpIdentityRequiresGoalRefresh: vi.fn(() => false),
  captureArtifactWorkspace: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard-test'),
  route: {
    value: {
      tab: 'workspace',
      params: { section: 'planning' } as Record<string, string>,
      postId: null,
    },
  },
}))

vi.mock('../../api/dashboard', () => ({
  fetchDashboardGoalDetail: mocks.fetchDashboardGoalDetail,
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
}))

vi.mock('../../api/published-artifacts', async original => ({
  ...await original<typeof import('../../api/published-artifacts')>(),
  captureArtifactWorkspace: mocks.captureArtifactWorkspace,
}))

vi.mock('../../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/core')>(),
  currentDashboardActor: mocks.currentDashboardActor,
  get: mocks.get,
}))

// GoalCreateForm reaches the store and the toast through goal-create-state;
// neither is under test here.
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  return { refreshGoals: vi.fn(), executionWorkspaceAuthority: signal(null), executionError: signal(null), executionLoading: signal(false), refreshExecution: mocks.refreshExecution }
})

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpToolAtIdentity: (name: string, args: unknown, identity: unknown) => {
    mocks.callIdentity(identity)
    return mocks.callMcpTool(name, args)
  },
  mcpCallFailureDisposition: mocks.mcpCallFailureDisposition,
  mcpIdentityRequiresGoalRefresh: mocks.mcpIdentityRequiresGoalRefresh,
}))

vi.mock('../../router', () => ({
  route: mocks.route,
}))

vi.mock('../task-manage/task-create-form', () => ({
  TaskCreateForm: () => null,
}))

import { GoalTree, _testResetGoalActionReceipts } from './goal-tree'
import { executionError, executionWorkspaceAuthority } from '../../store'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { resetDashboardSessionActorForTests, setCanonicalDashboardActor } from '../../lib/dashboard-session-actor'
import { showToast } from '../common/toast'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'
import { showGoalCreate } from './goal-create-state'
import { fetchDashboardGoalsTree as decodeGoalTree, GoalSourceUnavailableError } from '../../api/dashboard-goals'

const measurementFixture = JSON.parse(readFileSync(
  resolve(__dirname, '../../api/fixtures/goal-measurement-tree.json'), 'utf8',
))

function emptySummary(): DashboardGoalsTreeResponse['summary'] {
  return {
    total_goals: 0,
    active_goals: 0,
    phase_counts: {},
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
  }
}

function makeGoal(id: string, title: string, children: GoalTreeNode[] = []): GoalTreeNode {
  return {
    id,
    title,
    phase: 'executing',
    phase_color: '',
    goal_fsm: {
      state: 'executing',
      source: 'goal.phase',
      next_actions: ['request_complete', 'drop', 'pause', 'block'],
      activity_observation: 'goal_metadata',
    },
    priority: 3,
    metric: null,
    target_value: null,
    due_date: null,
    criterion_revision: 'revision-default',
    verification: { state: 'current', completion: { state: 'idle' } },
    measurement: { state: 'not_recorded' },
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    timeline_events: [],
    children,
    child_count: children.length,
    last_activity_at: '2026-05-25T00:00:00Z',
    stagnation_seconds: 0,
    activity_observation: 'goal_metadata',
    linked_keeper_names: [],
    pending_approval_count: 0,
    created_at: '2026-05-25T00:00:00Z',
    updated_at: '2026-05-25T00:00:00Z',
  }
}

describe('GoalTree', () => {
  beforeEach(() => {
    _testResetGoalActionReceipts()
    ;(executionError as { value: string | null }).value = null
    mocks.refreshExecution.mockResolvedValue(undefined)
    clearStoredToken()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    mocks.captureArtifactWorkspace.mockImplementation(async (basePath: string) => ({ basePath, mascRoot: `${basePath}/.masc` }))
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning' },
      postId: null,
    }
    hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: emptySummary(),
    })
  })

  afterEach(() => {
    cleanup()
    showGoalCreate.value = false
    resetGoalCreateFormLocal()
    mocks.callMcpTool.mockReset()
    mocks.callIdentity.mockReset()
    mocks.refreshExecution.mockReset()
    mocks.mcpCallFailureDisposition.mockReset().mockReturnValue('known_tool_response')
    mocks.mcpIdentityRequiresGoalRefresh.mockReset().mockReturnValue(false)
    mocks.captureArtifactWorkspace.mockReset()
    mocks.currentDashboardActor.mockReset()
    mocks.currentDashboardActor.mockReturnValue('dashboard-test')
    mocks.fetchDashboardGoalDetail.mockReset()
    mocks.fetchDashboardGoalsTree.mockReset()
    mocks.get.mockReset()
    clearStoredToken()
    resetDashboardSessionActorForTests()
  })

  it('renders the decoded wire measurement with its criterion and evidence', async () => {
    mocks.get.mockResolvedValue(measurementFixture)
    const decoded = await decodeGoalTree()
    const measured = decoded.tree[0]!
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning', goal: measured.id },
      postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(decoded)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal: measured, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    } satisfies DashboardGoalDetailResponse)

    render(html`<${GoalTree} />`)
    await waitFor(() => {
      expect(screen.getByTestId('goal-measurement-detail').getAttribute('data-state')).toBe('reported')
    })
    expect(screen.getByTestId('goal-observed-value').textContent).toBe('7')
    expect(screen.getByTestId('goal-measurement-evidence').textContent).toContain('artifact:seven-passing-cases')
    expect(screen.getByTestId('goal-criterion-revision').textContent).toContain(measured.criterion_revision)
    expect(screen.getByTestId('goal-measurement-badge-goal-measured').textContent).toContain('관측 7')
    expect(screen.getByTestId('goal-measurement-badge-goal-unavailable').textContent).toContain('측정 저장소 읽기 실패')
  })

  it('keeps the measurement detail in sync with a refreshed tree', async () => {
    mocks.get.mockResolvedValue(measurementFixture)
    const first = await decodeGoalTree()
    const updated = structuredClone(first)
    const measurement = updated.tree[0]!.measurement
    if (measurement.state !== 'reported') throw new Error('fixture needs a reported measurement')
    updated.tree[0]!.measurement = {
      state: 'reported', record: { ...measurement.record, observed_value: '8' },
    }
    mocks.route.value = {
      tab: 'workspace', params: { section: 'planning', goal: first.tree[0]!.id }, postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(first).mockResolvedValueOnce(updated)
    // Detail remains on the earlier response while the tree refreshes.
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal: first.tree[0]!, linked_tasks: [], linked_keepers: [], approvals: [],
      execution_receipts: [], timeline: [],
    } satisfies DashboardGoalDetailResponse)

    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-observed-value').textContent).toBe('7'))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(screen.getByTestId('goal-observed-value').textContent).toBe('8'))
    expect(screen.getByTestId('goal-measurement-badge-goal-measured').textContent).toContain('관측 8')
  })

  it('selects and expands the goal from the planning route focus', async () => {
    const child = makeGoal('goal-child', 'Child goal')
    const parent = makeGoal('goal-parent', 'Parent goal', [child])
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [parent],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal: child,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.route.value = {
      tab: 'workspace',
      params: { section: 'planning', goal: 'goal-child' },
      postId: null,
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    const { container } = render(html`<${GoalTree} />`)

    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-child')
    })
    expect(screen.getAllByText('Child goal').length).toBeGreaterThan(0)
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledWith('goal-child',
        { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' })
    })
  })

  it('requests goal completion through the goal transition tool and refreshes goal data', async () => {
    const goal = {
      ...makeGoal('goal-ready', 'Ready goal'),
      task_count: 1,
      task_done_count: 1,
    } satisfies GoalTreeNode
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1, total_tasks: 1, done_tasks: 1 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)
    mocks.callMcpTool.mockResolvedValue('{"ok":true}')

    render(html`<${GoalTree} />`)

    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-ready')
    })
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))

    await waitFor(() => {
      expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
        goal_id: 'goal-ready',
        action: 'request_complete',
        expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
        expected_verification: { phase: 'executing', criterion_revision: 'revision-default' },
      })
    })
    expect(mocks.callIdentity).toHaveBeenCalledWith({ revision: expect.any(Number), actor: 'dashboard-test' })
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThanOrEqual(2)
      expect(mocks.fetchDashboardGoalDetail.mock.calls.length).toBeGreaterThanOrEqual(2)
    })
    expect(screen.getByTestId('goal-lifecycle-action-status').textContent)
      .toContain('Request completion applied')
  })

  it('drops a Goal only with the reason the operator writes', async () => {
    const goal = makeGoal('goal-drop', 'Goal to drop')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue('{"ok":true}')
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Drop' })).toBeTruthy())

    fireEvent.click(screen.getByRole('button', { name: 'Drop' }))
    const reason = document.querySelector<HTMLTextAreaElement>('[data-goal-drop-reason] textarea')
    expect(reason).not.toBeNull()
    const submit = screen.getByRole('button', { name: 'Drop goal' }) as HTMLButtonElement
    expect(submit.disabled).toBe(true)
    fireEvent.input(reason!, { target: { value: '   ' } })
    expect(submit.disabled).toBe(true)
    expect(mocks.callMcpTool).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!,
      { target: { value: '  superseded by goal-next  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-drop', action: 'drop', note: 'superseded by goal-next',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
    }))
    await waitFor(() => expect(document.querySelector('[data-goal-drop-reason]')).toBeNull())
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['{"ok":true}', 'Verification retry requested'],
    ['{"ok":true,"reconciled":true}', 'Existing verification reconciled'],
  ])('shows the server outcome for a verifying Goal: %s', async (response, status) => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-verifying-retry', 'Goal awaiting verification'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'proof-request-1',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Goal awaiting verification', metric: null, target_value: null } } },
      goal_fsm: {
        state: 'verifying', source: 'goal.phase',
        next_actions: ['request_complete', 'drop', 'reopen', 'pause', 'block'],
        activity_observation: 'goal_metadata',
      },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue(response)
    render(html`<${GoalTree} />`)

    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-verifying-retry', action: 'request_complete',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
      expected_verification: { phase: 'verifying', criterion_revision: 'revision-default', request_id: 'proof-request-1' },
    }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent)
      .toContain(status))
  })

  it('does not claim a retry when the original execution is unresolved', async () => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-unknown', 'Unknown verification'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'request-unknown',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Unknown verification', metric: null, target_value: null } } },
      goal_fsm: { state: 'verifying', source: 'goal.phase', next_actions: ['request_complete', 'reopen'],
        activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockRejectedValue(new Error('original outcome is unknown; no new review was started'))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-error').textContent)
      .toContain('original outcome is unknown'))
    expect(screen.getByTestId('goal-lifecycle-action-binding').textContent).toContain('request-unknown')
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
  })

  it('retains an unknown transport outcome for the original Goal after navigation', async () => {
    const first = makeGoal('goal-transport-origin', 'Transport origin')
    const second = makeGoal('goal-transport-other', 'Transport other')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    fireEvent.click(screen.getByRole('button', { name: /Transport other/ }))
    rejectAction(new Error('POST /mcp: timeout'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('요청 결과를 확인하지 못했습니다'), 'error'))
    fireEvent.click(screen.getByRole('button', { name: /Transport origin/ }))
    const receipt = await screen.findByTestId('goal-lifecycle-action-error')
    expect(receipt.textContent).toContain('다시 시도하기 전에 원래 Goal 상태를 확인하세요')
    expect(receipt.textContent).toContain('POST /mcp: timeout')
  })

  it('keeps an earlier unknown proof result when a later Goal action completes', async () => {
    const goal: GoalTreeNode = {
      ...makeGoal('goal-history', 'Goal with history'), phase: 'verifying',
      verification: { state: 'current', completion: { state: 'pending', requestId: 'proof-original',
        requestedAt: '2026-10-30T07:45:56Z', criterion: { revision: 'revision-default',
          title: 'Goal with history', metric: null, target_value: null } } },
      goal_fsm: { state: 'verifying', source: 'goal.phase',
        next_actions: ['request_complete', 'pause'], activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockRejectedValueOnce(new Error('original outcome unknown')).mockResolvedValueOnce('{"ok":true}')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry verification' }))
    await screen.findByTestId('goal-lifecycle-action-error')
    fireEvent.click(screen.getByRole('button', { name: 'Pause' }))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent).toContain('Pause applied'))
    expect(screen.getByTestId('goal-lifecycle-action-history').textContent).toContain('original outcome unknown')
    expect(screen.getByTestId('goal-lifecycle-action-history').textContent).toContain('proof-original')
  })

  it.each(['success', 'failure'] as const)('keeps a %s response with its original Goal after navigation', async outcome => {
    const first = makeGoal('goal-origin', 'Origin goal')
    const second = makeGoal('goal-selected', 'Selected goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [first, second],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockImplementation(async (id: string) => ({
      goal: id === first.id ? first : second,
      linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    }))
    let resolveAction!: (value: string) => void
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((resolve, reject) => {
      resolveAction = resolve
      rejectAction = reject
    }))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(first.id))
    fireEvent.click(screen.getByRole('button', { name: 'Request completion' }))
    fireEvent.click(screen.getByRole('button', { name: /Selected goal/ }))
    await waitFor(() => expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id))
    const firstReads = mocks.fetchDashboardGoalDetail.mock.calls.filter(([id]) => id === first.id).length
    if (outcome === 'success') resolveAction('{"ok":true}')
    else rejectAction(new Error('original outcome is unknown'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      outcome === 'success' ? 'Goal goal-origin: Request completion applied' : expect.stringContaining('Goal goal-origin: original outcome is unknown'),
      ...(outcome === 'success' ? [] : ['error']),
    ))
    expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id')).toBe(second.id)
    expect(mocks.fetchDashboardGoalDetail.mock.calls.filter(([id]) => id === first.id)).toHaveLength(firstReads)
    fireEvent.click(screen.getByRole('button', { name: /Origin goal/ }))
    const result = await screen.findByTestId(outcome === 'success' ? 'goal-lifecycle-action-status' : 'goal-lifecycle-action-error')
    expect(result.textContent).toContain(outcome === 'success' ? 'Request completion applied' : 'original outcome is unknown')
  })

  it('does not apply an old workspace response to the same Goal id in a new workspace', async () => {
    const goal = makeGoal('goal-same-id', 'Workspace goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(1))
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
    await waitFor(() => expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledWith(goal.id,
      { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }))
    const reads = mocks.fetchDashboardGoalDetail.mock.calls.length
    resolveAction('{"ok":true}')
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      'Goal goal-same-id: 이전 연결에서 요청 결과가 도착했습니다. 해당 workspace에서 상태를 확인하세요.', 'warning',
    ))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledTimes(reads)
  })

  it('keeps the original request result when the server restarts on the same workspace', async () => {
    const goal = makeGoal('goal-restarted-server', 'Restarted server goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(true))
    rejectAction(new Error('connection closed'))
    const prior = await screen.findByTestId('goal-lifecycle-previous-connection')
    await waitFor(() => expect(prior.textContent).toContain('요청 결과를 확인하지 못했습니다'))
    expect(prior.textContent).toContain('connection closed')
    expect(prior.textContent).toContain('revision-default')
    expect(prior.textContent).toContain('같은 workspace인지는 확인되지 않았습니다')
    expect(screen.queryByTestId('goal-lifecycle-action-error')).toBeNull()
  })

  it('keeps a managed dev actor receipt and draft across token rotation', async () => {
    setStoredToken('dev-token-one', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const goal = makeGoal('goal-dev-rotation', 'Dev rotation goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Retain this reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token-two', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('connection closed'))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-error').textContent).toContain('connection closed'))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Retain this reason')
  })

  it('blocks a different credential during an earlier request without exposing its result', async () => {
    setStoredToken('manual-token-a', { source: 'manual' })
    const goal = makeGoal('goal-credential-pending', 'Credential pending goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('manual-token-b', { source: 'manual' })
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(true))
    rejectAction(new Error('private prior result'))
    await screen.findByText(/다른 연결 또는 인증의 Goal 요청 결과가 확인되지 않았습니다/)
    expect(screen.queryByText(/private prior result/)).toBeNull()
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('reports when bootstrap changes the credential before sending', async () => {
    const goal = makeGoal('goal-before-dispatch', 'Before dispatch goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.mcpIdentityRequiresGoalRefresh.mockReturnValue(true)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('changed before dispatch'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('Goal을 변경하지 않았습니다'), 'warning'))
  })

  it('reloads an initial read when the unauthenticated actor changes', async () => {
    const goal = makeGoal('goal-actor-read', 'Actor read goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let actor = 'actor-a'
    let resolveOld!: (tree: DashboardGoalsTreeResponse) => void
    mocks.currentDashboardActor.mockImplementation(() => actor)
    mocks.fetchDashboardGoalsTree.mockImplementation(() => actor === 'actor-a'
      ? new Promise(resolve => { resolveOld = resolve }) : Promise.resolve(tree))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalled())
    actor = 'actor-b'
    setCanonicalDashboardActor('actor-b')
    await screen.findByRole('button', { name: 'Request completion' })
    resolveOld(tree)
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
  })

  it('retains a pending bearer request when its canonical actor arrives', async () => {
    setStoredToken('manual-bearer', { source: 'manual' })
    const goal = makeGoal('goal-actor-hint', 'Actor hint goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    mocks.currentDashboardActor.mockReturnValue('alice')
    setCanonicalDashboardActor('alice')
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(true))
    resolveAction('{"ok":true}')
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-action-status').textContent).toContain('Request completion applied'))
  })

  it('keeps a drop reason with its originating workspace', async () => {
    const goal = makeGoal('goal-drop-owner', 'Drop owner goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'A reason' } })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith(
      { basePath: '/workspace-b', mascRoot: '/workspace-b/.masc' }))
    await waitFor(() => expect(document.querySelector('[data-goal-drop-reason]')).toBeNull())
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('offers an explicit copy of an unsent draft from a previous server connection', async () => {
    const goal = makeGoal('goal-draft-restart', 'Draft restart goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Original reason' } })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-restarted', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    const previousDraft = await screen.findByTestId('goal-drop-previous-drafts')
    expect(previousDraft.textContent).toContain('Original reason')
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Original reason')
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
  })

  it('offers an anonymous dashboard draft after dev-token bootstrap', async () => {
    mocks.currentDashboardActor.mockReturnValue('dashboard')
    const goal = makeGoal('goal-draft-bootstrap', 'Bootstrap draft goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('known_pre_effect')
    mocks.mcpIdentityRequiresGoalRefresh.mockReturnValue(true)
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Saved before login' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    rejectAction(new Error('changed before dispatch'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('Goal을 변경하지 않았습니다'), 'warning'))
    expect((await screen.findByTestId('goal-drop-previous-drafts')).textContent).toContain('Saved before login')
    expect(document.querySelector('[data-goal-drop-reason]')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }))
    expect((document.querySelector('[data-goal-drop-reason] textarea') as HTMLTextAreaElement).value).toBe('Saved before login')
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('blocks a new dev action while an anonymous dashboard request remains pending', async () => {
    mocks.currentDashboardActor.mockReturnValue('dashboard')
    const goal = makeGoal('goal-pending-bootstrap', 'Pending bootstrap goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let rejectAction!: (error: Error) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>((_resolve, reject) => { rejectAction = reject }))
    mocks.mcpCallFailureDisposition.mockReturnValue('outcome_unknown')
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Drop' }))
    fireEvent.input(document.querySelector('[data-goal-drop-reason] textarea')!, { target: { value: 'Pending reason' } })
    fireEvent.click(screen.getByRole('button', { name: 'Drop goal' }))
    setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    await screen.findByTestId('goal-lifecycle-previous-connection')
    expect((screen.getByRole('button', { name: 'Drop' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: '이 사유를 현재 입력에 복사' }) as HTMLButtonElement).disabled).toBe(true)
    rejectAction(new Error('connection closed'))
    await waitFor(() => expect(screen.getByTestId('goal-lifecycle-previous-connection').textContent).toContain('connection closed'))
    expect(mocks.callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('does not send an action from the previous workspace tree while the new tree is loading', async () => {
    const goal = makeGoal('goal-cloned', 'Cloned goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let resolveNext!: (value: DashboardGoalsTreeResponse) => void
    mocks.fetchDashboardGoalsTree.mockResolvedValueOnce(tree)
      .mockImplementationOnce(() => new Promise(resolve => { resolveNext = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    resolveNext(tree)
    expect((await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false)
  })

  it('keeps an action with the captured masc root when the same base changes roots', async () => {
    const goal = makeGoal('goal-root-swap', 'Root swap goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    let root = '/root-a'
    mocks.captureArtifactWorkspace.mockImplementation(async () => ({ basePath: '/workspace-a', mascRoot: root }))
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    fireEvent.click(button)
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', expect.objectContaining({
      expected_workspace: { base_path: '/workspace-a', masc_root: '/root-a' },
    })))
    root = '/root-b'
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledWith(
      { basePath: '/workspace-a', mascRoot: '/root-b' }))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Request completion' }) as HTMLButtonElement).disabled).toBe(false))
    resolveAction('{"ok":true}')
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(
      'Goal goal-root-swap: 이전 연결에서 요청 결과가 도착했습니다. 해당 workspace에서 상태를 확인하세요.', 'warning',
    ))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
  })

  it.each(['empty', 'url'] as const)('does not expose a %s credential receipt after switching to a dev token', async initial => {
    if (initial === 'url') {
      mocks.currentDashboardActor.mockReturnValue('dashboard')
      setStoredToken('test-url-token', { source: 'url' })
    }
    const goal = makeGoal('goal-bootstrap', 'Bootstrap goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    let resolveAction!: (value: string) => void
    mocks.callMcpTool.mockImplementation(() => new Promise<string>(resolve => { resolveAction = resolve }))
    render(html`<${GoalTree} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Request completion' }))
    setStoredToken('test-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 2 }
    resolveAction('{"ok":true}')
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.stringContaining('이전 연결에서 요청 결과'), 'warning'))
    expect(screen.queryByTestId('goal-lifecycle-action-status')).toBeNull()
    expect(screen.queryByTestId('goal-lifecycle-previous-connection')).toBeNull()
  })

  it('waits for the initial workspace observation before sending an action', async () => {
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    const goal = makeGoal('goal-wait', 'Waiting goal')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue('{"ok":true}')
    render(html`<${GoalTree} />`)
    await screen.findByText(/workspace를 확인할 수 없습니다/)
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-a', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    fireEvent.click(button)
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledTimes(1))
  })

  it('shows a workspace observation failure and retries its source', async () => {
    ;(executionWorkspaceAuthority as { value: unknown }).value = null
    ;(executionError as { value: string | null }).value = 'execution unavailable'
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [], summary: emptySummary(),
    })
    render(html`<${GoalTree} />`)
    await screen.findByText(/execution unavailable/)
    fireEvent.click(screen.getByRole('button', { name: '다시 확인' }))
    expect(mocks.refreshExecution).toHaveBeenCalledWith({ force: true })
  })

  it('rechecks the workspace after another source replaces the shared tree', async () => {
    const goal = makeGoal('goal-shared-refresh', 'Shared refresh goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    const button = await screen.findByRole('button', { name: 'Request completion' }) as HTMLButtonElement
    await waitFor(() => expect(button.disabled).toBe(false))
    const reads = mocks.fetchDashboardGoalsTree.mock.calls.length
    hydrateGoalTreeSnapshot(tree)
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThan(reads))
    await waitFor(() => expect(button.disabled).toBe(false))
  })

  it.each([
    ['paused', 'resume', 'Resume', 'verifying'],
    ['blocked', 'unblock', 'Unblock', 'awaiting_confirmation'],
  ] as const)('restores a %s Goal using server actions', async (phase, action, label, restore) => {
    const goal = {
      ...makeGoal('goal-suspended', 'Suspended goal'), phase, resume_phase: restore,
      goal_fsm: { state: phase, source: 'goal.phase', next_actions: [action, 'drop', 'reopen'], activity_observation: 'goal_metadata' },
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, phase_counts: { [phase]: 1 } },
    })
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    mocks.callMcpTool.mockResolvedValue('{"ok":true}')
    render(html`<${GoalTree} />`)
    await waitFor(() => expect(screen.getByRole('button', { name: label })).toBeTruthy())
    expect(document.querySelector('[data-goal-resume-phase]')?.textContent).toContain('재개 시')
    expect(screen.queryByRole('button', { name: 'Request completion' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: label }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_transition', {
      goal_id: 'goal-suspended', action, expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
    }))
  })

  it('renders a verifying goal with phase label, filter chip, and summary count', async () => {
    const goal = { ...makeGoal('goal-verifying', 'Verifying goal'), phase: 'verifying' }
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: {
        ...emptySummary(),
        total_goals: 1,
        active_goals: 1,
        phase_counts: { verifying: 1 },
      },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    render(html`<${GoalTree} />`)

    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-verifying')
    })
    // Tree node badge and the phase filter chip both render the Korean label.
    expect(screen.getAllByText('검증 중').length).toBeGreaterThanOrEqual(2)
  })

  it('renders a loading indicator while the goal tree is refreshing', async () => {
    const goal = makeGoal('goal-loading', 'Loading goal')
    const treePayload: DashboardGoalsTreeResponse = {
      approval_queue_state: { state: 'ready' },
      tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    }
    const detailPayload: DashboardGoalDetailResponse = {
      goal,
      linked_tasks: [],
      linked_keepers: [],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    }
    let resolveTree: (value: unknown) => void = () => {}
    mocks.fetchDashboardGoalsTree.mockImplementation(() => new Promise(resolve => { resolveTree = resolve }))
    mocks.fetchDashboardGoalDetail.mockResolvedValue(detailPayload)

    render(html`<${GoalTree} />`)

    expect(screen.getByText('goal manager 로드 중...')).toBeTruthy()
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1))
    resolveTree(treePayload)
    await waitFor(() => {
      expect(screen.queryByTestId('goal-tree-loading')).toBeNull()
    })
  })

  // RFC-0444 §2.3 row 4 / criterion 9: a Goal store this build cannot read is
  // drawn as an alert with file · reason · mirror · reset step, and the create
  // form refuses to submit while that state stands.
  it('keeps a Goal store error from an earlier workspace out of the new workspace view', async () => {
    const failure = new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/workspace-a/private-goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    })
    mocks.fetchDashboardGoalsTree.mockImplementation((workspace: { basePath: string }) =>
      workspace.basePath === '/workspace-a' ? Promise.reject(failure) : new Promise(() => {}))
    render(html`<${GoalTree} />`)
    expect((await screen.findByTestId('goal-store-unavailable')).textContent).toContain('/workspace-a/private-goals.json')
    ;(executionWorkspaceAuthority as { value: unknown }).value =
      { epoch: 'fixture-b', workspaceRoot: '/workspace-b', connectionGeneration: 2 }
    await waitFor(() => expect(screen.queryByTestId('goal-store-unavailable')).toBeNull())
  })

  it('shows a workspace-bound Goal store failure returned by detail', async () => {
    const goal = makeGoal('goal-detail-store-failure', 'Detail store failure')
    mocks.fetchDashboardGoalsTree.mockResolvedValue({
      approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })
    mocks.fetchDashboardGoalDetail.mockRejectedValue(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/workspace-a/detail-goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    }))
    render(html`<${GoalTree} />`)
    expect((await screen.findByTestId('goal-store-unavailable')).textContent).toContain('/workspace-a/detail-goals.json')
  })

  it('rechecks an unowned shared Goal store error without showing its contents', async () => {
    const goal = makeGoal('goal-shared-error', 'Shared error goal')
    const tree = { approval_queue_state: { state: 'ready' }, tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 } } satisfies DashboardGoalsTreeResponse
    mocks.fetchDashboardGoalsTree.mockResolvedValue(tree)
    mocks.fetchDashboardGoalDetail.mockResolvedValue({
      goal, linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [],
    })
    render(html`<${GoalTree} />`)
    await screen.findByRole('button', { name: 'Request completion' })
    const count = mocks.fetchDashboardGoalsTree.mock.calls.length
    mocks.fetchDashboardGoalsTree.mockImplementation(() => new Promise(() => {}))
    hydrateGoalTreeError(new GoalSourceUnavailableError({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/other-workspace/private.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    }))
    await waitFor(() => expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThan(count))
    expect(screen.queryByText('/other-workspace/private.json')).toBeNull()
  })

  it('draws the Goal store failure as an alert and refuses goal creation', async () => {
    mocks.fetchDashboardGoalsTree.mockRejectedValue(new GoalSourceUnavailableError({
      kind: 'unavailable',
      reason: 'schema_rejected',
      field: 'criterion_revision',
      file: '/srv/masc/.masc/goals.json',
      mirror: { status: 'mirror_decodes', goalCount: 97 },
      resetStep: 'repair_field',
    }))
    showGoalCreate.value = true

    render(html`<div><${GoalTree} /><${GoalCreateForm} /></div>`)

    const alert = await waitFor(() => screen.getByTestId('goal-store-unavailable'))
    expect(alert.getAttribute('role')).toBe('alert')
    expect(alert.getAttribute('data-reason')).toBe('schema_rejected')
    expect(alert.getAttribute('data-reset-step')).toBe('repair_field')
    expect(alert.textContent).toContain('Goal store 를 읽을 수 없습니다')
    expect(screen.getByTestId('goal-store-unavailable-file').textContent).toBe('/srv/masc/.masc/goals.json')
    expect(screen.getByTestId('goal-store-unavailable-reason').textContent)
      .toBe('이 빌드의 goal 스키마가 파일을 거절했습니다 (필드: criterion_revision)')
    expect(screen.getByTestId('goal-store-unavailable-mirror').textContent)
      .toBe('.last-good 미러는 읽힘 · goal 97개 (서빙하지 않음)')
    expect(screen.getByTestId('goal-store-unavailable-reset-step').textContent)
      .toBe('필드 criterion_revision 를 채우면 다시 읽힙니다')
    // The generic ErrorState line is not drawn beside the structured block.
    expect(container_alerts()).toEqual(['goal-store-unavailable', 'goal-create-source-unavailable'])

    fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'Recover the store' } })
    fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'readable goals' } })
    fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '97' } })
    const submit = screen.getByTestId('goal-create-submit') as HTMLButtonElement
    expect(submit.disabled).toBe(true)
    fireEvent.click(submit)
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(screen.getByTestId('goal-create-source-unavailable').getAttribute('role')).toBe('alert')
    expect(screen.getByTestId('goal-create-source-unavailable').textContent).toContain('/srv/masc/.masc/goals.json')
    expect(screen.getByTestId('goal-create-source-unavailable').textContent).toContain('criterion_revision')
  })

  it('offers goal creation again once the tree hydrates after a Goal store failure', async () => {
    mocks.fetchDashboardGoalsTree.mockRejectedValueOnce(new GoalSourceUnavailableError({
      kind: 'unavailable',
      reason: 'not_json',
      field: null,
      file: '/srv/masc/.masc/goals.json',
      mirror: { status: 'mirror_absent', goalCount: null },
      resetStep: 'reset_goal_store',
    }))
    showGoalCreate.value = true
    render(html`<div><${GoalTree} /><${GoalCreateForm} /></div>`)
    await waitFor(() => screen.getByTestId('goal-store-unavailable'))

    hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: emptySummary(),
    })
    await waitFor(() => {
      expect(screen.queryByTestId('goal-store-unavailable')).toBeNull()
    })
    expect(screen.queryByTestId('goal-create-source-unavailable')).toBeNull()
    fireEvent.input(screen.getByTestId('goal-create-title-input'), { target: { value: 'Recover the store' } })
    fireEvent.input(screen.getByTestId('goal-create-metric'), { target: { value: 'readable goals' } })
    fireEvent.input(screen.getByTestId('goal-create-target'), { target: { value: '1' } })
    expect((screen.getByTestId('goal-create-submit') as HTMLButtonElement).disabled).toBe(false)
  })
})

function container_alerts(): string[] {
  return Array.from(document.querySelectorAll('[role="alert"]'))
    .map(node => node.getAttribute('data-testid') ?? '<no testid>')
}
