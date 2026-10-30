import { beforeEach, describe, expect, it } from 'vitest'

import {
  goalStoreUnavailable,
  goalTreeApprovalQueueState,
  goalTreeData,
  goalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from './goal-tree-state'

describe('goal tree approval queue authority', () => {
  beforeEach(() => {
    goalTreeApprovalQueueState.value = null
    goalStoreUnavailable.value = null
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
  it('projects a goal_store_unavailable bootstrap into the typed signal without inventing a Gate failure', () => {
    expect(hydrateGoalTreeSnapshot({
      ok: false, error_code: 'goal_store_unavailable', reason: 'not_json', field: null,
      file: '/srv/masc/.masc/goals.json', mirror: { status: 'mirror_absent', goal_count: null },
      reset_step: 'reset_goal_store',
    })).toBe(true)
    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toBeNull()
    expect(goalStoreUnavailable.value).toEqual({
      kind: 'unavailable', reason: 'not_json', field: null, file: '/srv/masc/.masc/goals.json',
      mirror: { status: 'mirror_absent', goalCount: null }, resetStep: 'reset_goal_store',
    })
    expect(goalTreeError.value).toContain('/srv/masc/.masc/goals.json')
    expect(goalTreeError.value).toContain('JSON')
    expect(goalTreeError.value).toContain('masc goals reset')
  })

  it('projects a goal_task_links_unavailable bootstrap as a rendered line without a Goal store failure', () => {
    expect(hydrateGoalTreeSnapshot({ok: false, error_code: 'goal_task_links_unavailable',
      error: 'goal_task_links: primary registry is missing'})).toBe(true)
    expect(goalTreeData.value).toBeNull()
    expect(goalTreeApprovalQueueState.value).toBeNull()
    expect(goalStoreUnavailable.value).toBeNull()
    expect(goalTreeError.value).toBe('goal_task_links: primary registry is missing')
  })

  it('clears the typed Goal store failure once a tree snapshot hydrates', () => {
    expect(hydrateGoalTreeSnapshot({
      ok: false, error_code: 'goal_store_unavailable', reason: 'missing_after_init', field: null,
      file: '/srv/masc/.masc/goals.json', mirror: { status: 'mirror_decodes', goal_count: 2 },
      reset_step: 'reset_goal_store',
    })).toBe(true)
    expect(goalStoreUnavailable.value?.reason).toBe('missing_after_init')
    expect(hydrateGoalTreeSnapshot({
      approval_queue_state: { state: 'ready' },
      tree: [],
      summary: { total_goals: 0, active_goals: 0, phase_counts: {}, total_tasks: 0, done_tasks: 0, pending_approvals: 0 },
    })).toBe(true)
    expect(goalStoreUnavailable.value).toBeNull()
    expect(goalTreeError.value).toBeNull()
  })

})
