import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from './dashboard-goals'

function validNode(id: string, title: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    title,
    status: 'active',
    phase: 'executing',
    priority: 1,
    tasks: [],
    children: [],
    ...overrides,
  }
}

function validTask(id: string, title: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    title,
    status: 'todo',
    priority: 1,
    assignee: null,
    goal_id: null,
    linkage_source: 'explicit',
    is_terminal: false,
    created_at: '2026-01-01',
    updated_at: '2026-01-02',
    ...overrides,
  }
}

function emptySummary() {
  return {
    total_goals: 0,
    active_goals: 0,
    phase_counts: {},
    total_tasks: 0,
    done_tasks: 0,
    pending_approvals: 0,
  }
}

const readyApprovalQueue = {
  approval_queue_state: { state: 'ready' as const },
}

afterEach(() => {
  vi.clearAllMocks()
})

describe('fetchDashboardGoalsTree decoding', () => {
  it('drops nodes missing required id, title, or status', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: [
        validNode('goal-valid', 'Valid goal'),
        { id: 'goal-no-title', status: 'active' },
        { id: 'goal-no-status', title: 'No status' },
        { title: 'No id', status: 'active' },
      ],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })

    const result = await fetchDashboardGoalsTree()

    expect(result.tree).toHaveLength(1)
    expect(result.tree[0]!.id).toBe('goal-valid')
    expect(result.tree[0]!.title).toBe('Valid goal')
  })

  it('drops tasks missing required id, title, or status', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: [
        validNode('goal-1', 'Goal one', {
          tasks: [
            validTask('task-valid', 'Valid task'),
            { id: 'task-no-title', status: 'todo' },
            { id: 'task-no-status', title: 'No status' },
            { title: 'No id', status: 'todo' },
          ],
        }),
      ],
      summary: { ...emptySummary(), total_goals: 1, total_tasks: 1 },
    })

    const result = await fetchDashboardGoalsTree()

    expect(result.tree[0]!.tasks).toHaveLength(1)
    expect(result.tree[0]!.tasks[0]!.id).toBe('task-valid')
  })

  it('drops malformed child nodes while keeping valid descendants', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: [
        validNode('goal-parent', 'Parent goal', {
          children: [
            validNode('goal-child', 'Child goal'),
            { id: 'bad-child', title: 'Bad child' },
          ],
        }),
      ],
      summary: { ...emptySummary(), total_goals: 2, active_goals: 2 },
    })

    const result = await fetchDashboardGoalsTree()

    expect(result.tree).toHaveLength(1)
    expect(result.tree[0]!.children).toHaveLength(1)
    expect(result.tree[0]!.children[0]!.id).toBe('goal-child')
  })

  it('backfills missing attainment metric_evaluation from metric presence', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: [
        validNode('goal-metric', 'Metric goal', {
          metric: 'coverage %',
          target_value: '80%',
          attainment: {
            state: 'attained',
            basis: 'metric_target_percent',
            metric: 'coverage %',
            attainment_pct: 100,
          },
        }),
      ],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })

    const result = await fetchDashboardGoalsTree()

    expect(result.tree[0]!.attainment.metric_evaluation).toBe('unevaluated')
  })

  it('marks missing attainment payload with declared metric as unevaluated', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: [
        validNode('goal-missing-attainment', 'Missing attainment', {
          metric: 'coverage %',
          target_value: '80%',
        }),
      ],
      summary: { ...emptySummary(), total_goals: 1, active_goals: 1 },
    })

    const result = await fetchDashboardGoalsTree()

    expect(result.tree[0]!.attainment.metric_evaluation).toBe('unevaluated')
    expect(result.tree[0]!.attainment.note).toBe('Attainment projection missing from payload.')
  })

  it('rejects a typed unavailable approval queue instead of decoding an empty tree', async () => {
    getMock.mockResolvedValue({
      generated_at: '2026-07-27T00:00:00Z',
      approval_queue_state: {
        state: 'unavailable',
        code: 'reset_required',
        title: 'Gate durable queue unavailable · runtime reset required',
        operator_detail: 'pending store requires reset',
        severity: 'bad',
        icon: '!',
      },
      tree: null,
      summary: null,
    })

    await expect(fetchDashboardGoalsTree()).rejects.toThrow(
      '! Gate durable queue unavailable · runtime reset required: pending store requires reset',
    )
  })

  it('rejects a missing approval queue state', async () => {
    getMock.mockResolvedValue({
      tree: [],
      summary: emptySummary(),
    })

    await expect(fetchDashboardGoalsTree()).rejects.toThrow(
      '유효하지 않은 dashboard goals approval_queue_state payload',
    )
  })

  it('rejects a malformed approval queue state', async () => {
    getMock.mockResolvedValue({
      approval_queue_state: { state: 'ready', legacy: true },
      tree: [],
      summary: emptySummary(),
    })

    await expect(fetchDashboardGoalsTree()).rejects.toThrow(
      '유효하지 않은 dashboard goals approval_queue_state payload',
    )
  })

  it('rejects null tree and summary under a ready queue state', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      tree: null,
      summary: null,
    })

    await expect(fetchDashboardGoalsTree()).rejects.toThrow()
  })

  it('preserves an explicit runtime snapshot failure in Goal detail', async () => {
    getMock.mockResolvedValue({
      ...readyApprovalQueue,
      goal: validNode('goal-runtime', 'Runtime goal'),
      linked_tasks: [],
      linked_keepers: [
        {
          name: 'keeper-a',
          agent_name: 'agent-a',
          current_task_id: null,
          active_goal_ids: ['goal-runtime'],
          sandbox_profile: 'workspace',
          network_mode: 'enabled',
          runtime_id: 'runtime-a',
          runtime_outcome: null,
          latest_execution_outcome: null,
          latest_execution_at: null,
          latest_receipt: null,
          runtime_trust: {
            snapshot_status: 'unavailable',
            snapshot_error: 'snapshot read failed',
          },
          latest_causal_event: null,
        },
      ],
      approvals: [],
      execution_receipts: [],
      timeline: [],
    })

    const result = await fetchDashboardGoalDetail('goal-runtime')

    expect(result.linked_keepers[0]?.runtime_trust).toMatchObject({
      snapshot_status: 'unavailable',
      snapshot_error: 'snapshot read failed',
    })
  })
})
