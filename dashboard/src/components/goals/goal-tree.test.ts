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

vi.mock('../../api/core', () => ({
  currentDashboardActor: mocks.currentDashboardActor,
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
})
