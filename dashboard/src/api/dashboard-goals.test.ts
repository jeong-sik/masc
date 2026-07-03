import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchDashboardGoalsTree } from './dashboard-goals'

function validNode(id: string, title: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    title,
    status: 'active',
    phase: 'executing',
    health: 'on_track',
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

afterEach(() => {
  vi.clearAllMocks()
})

describe('fetchDashboardGoalsTree decoding', () => {
  it('drops nodes missing required id, title, or status', async () => {
    getMock.mockResolvedValue({
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
})
