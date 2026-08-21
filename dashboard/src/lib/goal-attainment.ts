// Goal attainment presentation SSOT.
//
// The rule that a declared-but-unevaluated metric never reads as "attained"
// (task-1743) lives here rather than in one surface, so the Goals tree and the
// Work goal detail cannot disagree about the same projection. Every lookup is a
// closed record over the backend's enum tokens with the raw token as fallback:
// an unrecognised token surfaces itself instead of collapsing into a
// convenient-looking default.

import type { GoalAttainmentProjection } from '../types'

export type AttainmentTone = 'default' | 'ok' | 'warn' | 'bad'

// Task-derived attainment_pct must not read as a metric result when the goal
// declares a metric that no evaluator measures (task-1743): show "미평가"
// rather than a percentage. Distinct from "미측정" (no task data at all).
export function attainmentValueLabel(attainment: GoalAttainmentProjection): string {
  if (attainment.metric_evaluation === 'unevaluated') return '미평가'
  if (attainment.attainment_pct == null) return '미측정'
  return `${attainment.attainment_pct}%`
}

export function attainmentTone(attainment: GoalAttainmentProjection): AttainmentTone {
  // A declared-but-unevaluated metric is never "attained": the pct is
  // task-derived, so surface it as attention (warn), not success (ok).
  if (attainment.metric_evaluation === 'unevaluated') return 'warn'
  if (attainment.state === 'attained') return 'ok'
  if (attainment.state === 'unmeasured') return 'warn'
  if (attainment.state === 'not_started') return 'bad'
  return 'default'
}

const ATTAINMENT_STATE_LABEL: Record<string, string> = {
  attained: '달성',
  in_progress: '진행 중',
  not_started: '시작 전',
  unmeasured: '측정 안 됨',
}

export function attainmentStateLabel(state: string): string {
  return ATTAINMENT_STATE_LABEL[state] ?? state
}

const ATTAINMENT_BASIS_LABEL: Record<string, string> = {
  goal_phase: 'Goal 단계로만 판정',
  linked_tasks: '연결된 하위 작업 완료 수',
  metric_target_percent: '지표 목표치(%) 대비',
  metric_target_count: '지표 목표치(건수) 대비',
  unmeasured: '판정 근거 없음',
}

export function attainmentBasisLabel(basis: string): string {
  return ATTAINMENT_BASIS_LABEL[basis] ?? basis
}

const ATTAINMENT_UNIT_LABEL: Record<string, string> = {
  percent: '%',
  count: '건',
  unknown: '',
}

/** Suffix for a numeric observed/target value. Empty when the unit is unknown
 *  — a bare number is honest, an invented unit is not. */
export function attainmentUnitSuffix(unit: string): string {
  return ATTAINMENT_UNIT_LABEL[unit] ?? unit
}

const TARGET_PARSE_PROBLEM: Record<string, string> = {
  unparseable: '목표치를 숫자로 읽지 못했어요.',
  invalid_target: '목표치가 완료 판정에 쓸 수 없는 값이에요.',
  unsupported_metric: '이 지표는 자동으로 잴 수 있는 종류가 아니에요.',
  no_linked_tasks: '연결된 하위 작업이 없어서 진행률을 계산할 수 없어요.',
}

/** Why the declared target cannot drive completion, or null when it can.
 *  `absent` (no target declared) and `parseable` are not problems — the
 *  "목표치 없음" case is stated by the target row itself. */
export function attainmentTargetProblem(attainment: GoalAttainmentProjection): string | null {
  const status = attainment.target_parse_status
  if (status === 'absent' || status === 'parseable') return null
  return TARGET_PARSE_PROBLEM[status] ?? status
}

/** Why the attainment verdict is not a measurement of the declared metric,
 *  or null when no such caveat applies. The two `unevaluated` shapes differ:
 *  with a pct the panel is showing a task-derived stand-in, without one the
 *  goal has no completion verdict at all. */
export function attainmentEvaluationCaveat(attainment: GoalAttainmentProjection): string | null {
  if (attainment.metric_evaluation !== 'unevaluated') return null
  const metric = attainment.metric ?? '이 지표'
  if (attainment.attainment_pct == null && attainment.observed_value == null) {
    return `${metric} 값을 재는 평가기가 없어서, 완료 여부를 아직 판정하지 못했어요.`
  }
  return `${metric} 를 직접 잰 값이 아니라, 끝난 하위 작업 수로 대신 계산한 숫자예요.`
}

export interface AttainmentVerdict {
  readonly label: string
  readonly detail: string | null
  readonly tone: AttainmentTone
}

/** The one-line completion verdict for a goal.
 *
 *  When the declared metric was never evaluated the backend still fills
 *  `state` from the task-derived percentage, so a goal whose metric nobody
 *  measured can arrive carrying `state: 'attained'`. Printing that as 달성
 *  would state a measurement that does not exist, so the verdict reads 미평가
 *  and the task-derived percentage moves into the detail line, labelled for
 *  what it is. */
export function attainmentVerdict(attainment: GoalAttainmentProjection): AttainmentVerdict {
  const tone = attainmentTone(attainment)
  const pct = attainment.attainment_pct
  if (attainment.metric_evaluation === 'unevaluated') {
    return {
      label: '미평가',
      detail: pct == null ? null : `하위 작업 기준으로는 ${pct}%`,
      tone,
    }
  }
  return {
    label: attainmentStateLabel(attainment.state),
    detail: pct == null ? null : `${pct}%`,
    tone,
  }
}

/** What the goal's completion-request state actually means.
 *
 *  `completion_summary.ready_to_request_completion` is the goal phase and
 *  nothing else — the backend returns `phase = Executing` (see
 *  dashboard_goals_types_attainment.ml `ready_to_request_completion`), and no
 *  metric, target, or task count is consulted. Rendering its false branch as
 *  "the completion conditions are unmet" states a check that never ran: a
 *  blocked goal with every condition satisfied would still read that way.
 *  The completion `state` token carries the real reason, so the row reports
 *  that instead. An unrecognised token surfaces itself rather than collapsing
 *  into whichever sentence happens to look plausible. */
const COMPLETION_REQUEST_TEXT: Record<string, string> = {
  ready_for_completion: '지금 완료를 요청할 수 있어요.',
  verifying: '완료 요청이 접수돼서 검증 결과를 기다리는 중이에요.',
  blocked: '막혀 있는 동안에는 완료를 요청할 수 없어요.',
  paused: '멈춰 있는 동안에는 완료를 요청할 수 없어요.',
  completed: '완료됐어요.',
  dropped: '폐기된 목표예요.',
}

export function completionRequestText(state: string): string {
  return COMPLETION_REQUEST_TEXT[state] ?? state
}
