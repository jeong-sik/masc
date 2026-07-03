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
    on_track_goals: 0,
    done_goals: 0,
    paused_goals: 0,
    at_risk_goals: 0,
    blocked_goals: 0,
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
    infra_risk_count: 0,
    overall_convergence: 0,
    overall_convergence_pct: 0,
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
      stagnation_status: 'recent',
    },
    health: 'on_track',
    health_color: '',
    badges: [],
    status_reason: 'ready',
    priority: 3,
    metric: null,
    target_value: null,
    require_completion_approval: false,
    due_date: null,
    parent_goal_id: null,
    convergence: 0,
    convergence_pct: 0,
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
    verification_summary: {
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    },
    pending_verification_count: 0,
    timeline_events: [],
    children,
    child_count: children.length,
    last_activity_at: '2026-05-25T00:00:00Z',
    stagnation_seconds: 0,
    activity_observation: 'goal_metadata',
    stagnation_status: 'recent',
    linked_keeper_names: [],
    pending_approval_count: 0,
    infra_risk_count: 0,
    linkage_source: 'explicit',
    linkage_warning_count: 0,
    blocking_source: 'none',
    blocking_reason: '',
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
        gate: 'none',
        requires_verifier: false,
        requires_completion_approval: false,
        active_verification_request: false,
        blocking_source: 'none',
        blocking_reason: '',
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
