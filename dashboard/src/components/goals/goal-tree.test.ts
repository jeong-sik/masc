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
  workspaceFsmSnapshot: { value: null },
}))

vi.mock('../../api/dashboard', () => ({
  fetchDashboardGoalDetail: mocks.fetchDashboardGoalDetail,
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
}))

vi.mock('../../api/core', () => ({
  currentDashboardActor: mocks.currentDashboardActor,
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool: mocks.callMcpTool,
}))

vi.mock('../../router', () => ({
  route: mocks.route,
}))

vi.mock('../../store', () => ({
  workspaceFsmSnapshot: mocks.workspaceFsmSnapshot,
}))

vi.mock('../task-manage/task-create-form', () => ({
  TaskCreateForm: () => null,
}))

import { GoalTree } from './goal-tree'

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
    status: 'active',
    status_color: '',
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
    parent_goal_id: null,
    attainment: {
      state: 'unmeasured',
      basis: 'unmeasured',
      metric: null,
      metric_evaluation: 'absent',
      target_value: null,
      target_parse_status: 'absent',
      unit: 'unknown',
      observed_value: null,
      target_numeric: null,
      attainment_pct: null,
      task_done_count: 0,
      task_count: 0,
      note: '',
    },
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
    linkage_source: 'explicit',
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
    mocks.workspaceFsmSnapshot.value = null
    hydrateGoalTreeSnapshot({ tree: [], summary: emptySummary() })
  })

  afterEach(() => {
    cleanup()
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
      completion_summary: {
        state: 'ready_for_completion',
        pct: 100,
        pct_source: 'linked_tasks',
        attainment_state: 'attained',
        attainment_basis: 'linked_tasks',
        metric_evaluation: 'absent',
        task_total: 1,
        task_done: 1,
        task_open: 0,
        is_complete: false,
        is_terminal: false,
        ready_to_request_completion: true,
      },
    } satisfies GoalTreeNode
    const treePayload: DashboardGoalsTreeResponse = {
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

  it('does not render unevaluated metric completion pct as goal progress truth', async () => {
    const goal = {
      ...makeGoal('goal-unevaluated', 'Unevaluated metric goal'),
      metric: '신규 3축 갭 해소 PR 수',
      target_value: '6',
      task_count: 15,
      task_done_count: 5,
      attainment: {
        state: 'in_progress',
        basis: 'metric_target_count',
        metric: '신규 3축 갭 해소 PR 수',
        metric_evaluation: 'unevaluated',
        target_value: '6',
        target_parse_status: 'parseable',
        unit: 'count',
        observed_value: 5,
        target_numeric: 6,
        attainment_pct: 83,
        task_done_count: 5,
        task_count: 15,
        note: 'Derived from completed linked tasks against a count target.',
      },
      completion_summary: {
        state: 'in_progress',
        pct: 83,
        pct_source: 'attainment',
        attainment_state: 'in_progress',
        attainment_basis: 'metric_target_count',
        metric_evaluation: 'unevaluated',
        task_total: 15,
        task_done: 5,
        task_open: 9,
        is_complete: false,
        is_terminal: false,
        ready_to_request_completion: false,
      },
    } satisfies GoalTreeNode
    const treePayload: DashboardGoalsTreeResponse = {
      tree: [goal],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1, total_tasks: 15, done_tasks: 5 },
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

    const { container } = render(html`<${GoalTree} />`)

    await waitFor(() => {
      expect(screen.getByTestId('goal-detail-panel').getAttribute('data-selected-goal-id'))
        .toBe('goal-unevaluated')
    })
    const completion = container.querySelector('[data-goal-completion-summary]') as HTMLElement | null
    expect(completion).not.toBeNull()
    expect(completion?.textContent).toContain('metric unevaluated')
    expect(completion?.textContent).not.toContain('83%')
    expect(completion?.querySelector('[data-goal-completion-metric-evaluation="unevaluated"]'))
      .not.toBeNull()
  })

  it('renders a loading indicator while the goal tree is refreshing', async () => {
    const goal = makeGoal('goal-loading', 'Loading goal')
    const treePayload: DashboardGoalsTreeResponse = {
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
})
