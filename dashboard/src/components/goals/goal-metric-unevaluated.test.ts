import { describe, expect, it } from 'vitest'

import type { GoalAttainmentProjection } from '../../types'

import { attainmentValueLabel } from './goal-tree'

// task-1743: a goal.metric is stored but never evaluated (the convergence
// evaluator has no caller), so the attainment percentage is derived from
// linked task completion. The goal panel must not present that as a metric
// result. These tests pin the honest label the render helper produces.
const base: GoalAttainmentProjection = {
  state: 'attained',
  basis: 'metric_target_percent',
  metric: 'test coverage %',
  metric_evaluation: 'unevaluated',
  target_value: '80%',
  target_parse_status: 'parseable',
  unit: 'percent',
  observed_value: 100,
  target_numeric: 80,
  attainment_pct: 100,
  task_done_count: 4,
  task_count: 4,
  note: 'Derived from linked task completion against a percent target.',
}

describe('attainmentValueLabel — metric unevaluated (task-1743)', () => {
  it('shows 미평가 for a declared-but-unevaluated metric even at 100%', () => {
    // (b) task-derived 100% must not read as a met metric.
    expect(attainmentValueLabel({ ...base, metric_evaluation: 'unevaluated' })).toBe('미평가')
  })

  it('shows the task-derived percent when no metric is declared', () => {
    // A goal with no metric has no metric to conflate; the percent is honest.
    expect(
      attainmentValueLabel({ ...base, metric: null, metric_evaluation: 'absent' }),
    ).toBe('100%')
  })

  it('distinguishes 미측정 (no task data) from 미평가 (no evaluator)', () => {
    // (c) a genuinely unmeasured goal (no pct) is 미측정, distinct from the
    // 미평가 unevaluated-metric case above.
    expect(
      attainmentValueLabel({
        ...base,
        metric: null,
        metric_evaluation: 'absent',
        attainment_pct: null,
      }),
    ).toBe('미측정')
  })
})
