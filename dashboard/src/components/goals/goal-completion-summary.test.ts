import { describe, expect, it } from 'vitest'

import type { GoalAttainmentProjection, GoalTreeTask } from '../../types'

import {
  goalCompletionGateLabel,
  goalCompletionLabel,
  goalCompletionSummaryForNode,
  goalCompletionTone,
} from './goal-completion-summary'

const baseAttainment: GoalAttainmentProjection = {
  state: 'in_progress',
  basis: 'linked_tasks',
  metric: null,
  metric_evaluation: 'absent',
  target_value: null,
  target_parse_status: 'absent',
  unit: 'percent',
  observed_value: 50,
  target_numeric: 100,
  attainment_pct: 50,
  task_done_count: 1,
  task_count: 2,
  note: 'test',
}

const task = (id: string, done: boolean): GoalTreeTask => ({
  id,
  title: id,
  status: done ? 'completed' : 'pending',
  status_color: '#fff',
  priority: 3,
  assignee: done ? 'keeper-a' : null,
  goal_id: 'g1',
  linkage_source: 'explicit',
  is_terminal: done,
  created_at: '2026-05-25T00:00:00Z',
  updated_at: '2026-05-25T00:00:00Z',
})

describe('goalCompletionSummaryForNode', () => {
  it('uses backend completion_summary when present', () => {
    const summary = goalCompletionSummaryForNode({
      phase: 'executing',
      require_completion_approval: false,
      task_count: 0,
      task_done_count: 0,
      tasks: [],
      attainment: baseAttainment,
      completion_summary: {
        state: 'awaiting_verification',
        pct: 100,
        pct_source: 'attainment',
        attainment_state: 'attained',
        attainment_basis: 'metric_target_percent',
        metric_evaluation: 'unevaluated',
        task_total: 0,
        task_done: 0,
        task_open: 0,
        is_complete: false,
        is_terminal: false,
        ready_to_request_completion: false,
        gate: 'verification',
        requires_verifier: true,
        requires_completion_approval: false,
        active_verification_request: true,
        blocking_source: 'none',
        blocking_reason: '',
      },
      verification_summary: {
        effective_policy: null,
        open_request: null,
        latest_request: null,
        approve_count: 0,
        reject_count: 0,
        remaining_possible: 0,
      },
      blocking_source: 'none',
      blocking_reason: '',
    })

    expect(summary.state).toBe('awaiting_verification')
    expect(goalCompletionLabel(summary)).toBe('awaiting verification')
    expect(goalCompletionGateLabel(summary)).toBe('verification gate')
  })

  it('falls back to scattered goal fields without creating completion readiness', () => {
    const summary = goalCompletionSummaryForNode({
      phase: 'executing',
      require_completion_approval: true,
      task_count: 2,
      task_done_count: 2,
      tasks: [task('t1', true), task('t2', true)],
      attainment: { ...baseAttainment, state: 'attained', attainment_pct: 100 },
      verification_summary: {
        effective_policy: null,
        open_request: null,
        latest_request: null,
        approve_count: 0,
        reject_count: 0,
        remaining_possible: 0,
      },
      blocking_source: 'none',
      blocking_reason: '',
    })

    expect(summary.state).toBe('in_progress')
    expect(summary.pct).toBe(100)
    expect(summary.ready_to_request_completion).toBe(false)
    expect(goalCompletionTone(summary)).toBe('default')
    expect(goalCompletionGateLabel(summary)).toBe('approval required')
  })

  it('does not request completion for an unevaluated metric goal with task-derived attainment', () => {
    const summary = goalCompletionSummaryForNode({
      phase: 'executing',
      require_completion_approval: false,
      task_count: 2,
      task_done_count: 2,
      tasks: [task('t1', true), task('t2', true)],
      attainment: {
        ...baseAttainment,
        state: 'attained',
        basis: 'metric_target_percent',
        metric: 'coverage %',
        target_value: '80%',
        metric_evaluation: 'unevaluated',
        attainment_pct: 100,
      },
      verification_summary: {
        effective_policy: null,
        open_request: null,
        latest_request: null,
        approve_count: 0,
        reject_count: 0,
        remaining_possible: 0,
      },
      blocking_source: 'none',
      blocking_reason: '',
    })

    expect(summary.state).toBe('in_progress')
    expect(summary.pct).toBe(100)
    expect(summary.metric_evaluation).toBe('unevaluated')
    expect(summary.ready_to_request_completion).toBe(false)
  })
})
