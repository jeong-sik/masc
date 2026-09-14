import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardGoalDetailResponse,
  DashboardGoalsTreeResponse,
  GoalTreeNode,
} from '../../types'
import { hydrateGoalTreeSnapshot } from '../../goal-tree-state'

const mocks = vi.hoisted(() => ({
  fetchDashboardGoalDetail: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
  callMcpTool: vi.fn(),
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

vi.mock('../../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/core')>(),
  currentDashboardActor: mocks.currentDashboardActor,
}))

// GoalCreateForm reaches the store and the toast through goal-create-state;
// neither is under test here.
vi.mock('../../store', () => ({
  refreshGoals: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool: mocks.callMcpTool,
}))

vi.mock('../../router', () => ({
  route: mocks.route,
}))

vi.mock('../task-manage/task-create-form', () => ({
  TaskCreateForm: () => null,
}))

import { GoalTree } from './goal-tree'
import { GoalCreateForm, resetGoalCreateFormLocal } from './goal-create-form'
import { showGoalCreate } from './goal-create-state'
import { GoalSourceUnavailableError } from '../../api/dashboard-goals'

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
      next_actions: [],
      activity_observation: 'goal_metadata',
    },
    priority: 3,
    metric: null,
    target_value: null,
    due_date: null,
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
    mocks.currentDashboardActor.mockReset()
    mocks.currentDashboardActor.mockReturnValue('dashboard-test')
    mocks.fetchDashboardGoalDetail.mockReset()
    mocks.fetchDashboardGoalsTree.mockReset()
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
      expect(mocks.fetchDashboardGoalDetail).toHaveBeenCalledWith('goal-child')
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
        actor: {
          id: 'dashboard-test',
          display_name: 'dashboard-test',
        },
      })
    })
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalsTree.mock.calls.length).toBeGreaterThanOrEqual(2)
      expect(mocks.fetchDashboardGoalDetail.mock.calls.length).toBeGreaterThanOrEqual(2)
    })
    expect(screen.getByTestId('goal-lifecycle-action-status').textContent)
      .toContain('requested completion')
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

    expect(screen.getByTestId('goal-tree-loading')).toBeTruthy()
    resolveTree(treePayload)
    await waitFor(() => {
      expect(screen.queryByTestId('goal-tree-loading')).toBeNull()
    })
  })

  // RFC-0444 §2.3 row 4 / criterion 9: a Goal store this build cannot read is
  // drawn as an alert with file · reason · mirror · reset step, and the create
  // form refuses to submit while that state stands.
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
