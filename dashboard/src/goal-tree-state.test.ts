import { beforeEach, describe, expect, it } from 'vitest'

import {
  goalTreeApprovalQueueState,
  goalTreeData,
  goalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from './goal-tree-state'

describe('goal tree approval queue authority', () => {
  beforeEach(() => {
    goalTreeApprovalQueueState.value = null
    goalTreeData.value = null
    goalTreeError.value = null
  })

  it('clears a ready tree when the current typed state is unavailable', () => {
    expect(hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: {
        total_goals: 0,
        active_goals: 0,
        phase_counts: {},
        total_tasks: 0,
        done_tasks: 0,
        pending_approvals: 0,
      },
    })).toBe(true)

    const unavailable = {
      state: 'unavailable',
      code: 'reset_required',
      title: 'Gate durable queue unavailable · runtime reset required',
      operator_detail: 'pending store requires reset',
      severity: 'bad',
      icon: '!',
    } as const
    expect(hydrateGoalTreeSnapshot({
      approval_queue_state: unavailable,
      tree: null,
      summary: null,
    })).toBe(true)

    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toEqual(unavailable)
    expect(goalTreeError.value).toBe(
      '! Gate durable queue unavailable · runtime reset required: pending store requires reset',
    )
  })

  it('preserves a Goal source error without attributing it to the Gate', () => {
    expect(hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: {
        total_goals: 0,
        active_goals: 0,
        phase_counts: {},
        total_tasks: 0,
        done_tasks: 0,
        pending_approvals: 0,
      },
    })).toBe(true)

    hydrateGoalTreeObservationError(new Error('tree fetch failed'))

    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toBeNull()
    expect(goalTreeError.value).toBe('tree fetch failed')
  })
  it('projects a source-unavailable bootstrap envelope without inventing a Gate failure', () => {
    expect(hydrateGoalTreeSnapshot({ok: false, error_code: 'goal_store_unavailable',
      error: 'goals.json could not decode'})).toBe(true)
    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toBeNull()
    expect(goalTreeError.value).toBe('goals.json could not decode')
  })

})
