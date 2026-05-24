import { describe, expect, it } from 'vitest'

import {
  goalTaskCompletionLabel,
  goalTaskLinkageLabel,
  goalTaskSummaryForNode,
} from './goal-task-summary'

describe('goalTaskSummaryForNode', () => {
  it('uses backend task_summary when present', () => {
    const summary = goalTaskSummaryForNode({
      task_count: 99,
      task_done_count: 0,
      tasks: [],
      task_summary: {
        total: 3,
        done: 1,
        open: 1,
        terminal: 2,
        awaiting_verification: 0,
        cancelled: 1,
        unassigned: 2,
        completion_pct: 33,
        by_status: { completed: 1, pending: 1, cancelled: 1 },
        by_linkage_source: { explicit: 3 },
      },
    })

    expect(summary.total).toBe(3)
    expect(goalTaskCompletionLabel(summary)).toBe('1/3 done · 33%')
    expect(goalTaskLinkageLabel(summary)).toBe('explicit goal_id')
  })

  it('falls back to task rows for older payloads', () => {
    const summary = goalTaskSummaryForNode({
      task_count: 2,
      task_done_count: 1,
      tasks: [
        {
          id: 't1',
          title: 'done',
          status: 'completed',
          status_color: '#fff',
          priority: 3,
          assignee: 'keeper-a',
          goal_id: 'g1',
          linkage_source: 'explicit',
          is_terminal: true,
          created_at: '2026-05-25T00:00:00Z',
          updated_at: '2026-05-25T00:00:00Z',
        },
        {
          id: 't2',
          title: 'open',
          status: 'pending',
          status_color: '#fff',
          priority: 3,
          assignee: null,
          goal_id: 'g1',
          linkage_source: 'explicit',
          is_terminal: false,
          created_at: '2026-05-25T00:00:00Z',
          updated_at: '2026-05-25T00:00:00Z',
        },
      ],
    })

    expect(summary).toMatchObject({
      total: 2,
      done: 1,
      open: 1,
      terminal: 1,
      unassigned: 1,
      completion_pct: 50,
    })
    expect(summary.by_status).toMatchObject({ completed: 1, pending: 1 })
    expect(summary.by_linkage_source).toMatchObject({ explicit: 2 })
  })
})
