import { beforeEach, describe, expect, it } from 'vitest'

import {
  goalTreeApprovalQueueState,
  goalTreeData,
  goalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from './goal-tree-state'
import { gateObservationErrorState } from './lib/gate-observation-state'

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

  it('replaces stale ready state with the shared typed observation error', () => {
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

    const expected = gateObservationErrorState('tree fetch failed')
    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toEqual(expected)
    expect(goalTreeError.value).toBe(
      `${expected.icon} ${expected.title}: ${expected.operator_detail}`,
    )
  })
})
