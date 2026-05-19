import type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
} from '../api/schemas/keeper-composite'

export type CompositeObservation = {
  ts: number
  phase: KeeperCompositeSnapshot['phase']
  turn: KeeperCompositeSnapshot['turn_phase']
  decision: KeeperCompositeSnapshot['decision']['stage']
  cascade: KeeperCompositeSnapshot['cascade']['state']
  compaction: KeeperCompositeSnapshot['compaction']['stage']
  // 6th axis (LT-16-KCB Phase 3). Unknown backend-ahead values are kept
  // as raw strings; only a missing rollout-era key falls back to `clean`.
  breaker: string
}

export type LaneKey = keyof Omit<CompositeObservation, 'ts'>

export function extractLaneValue(
  snapshot: KeeperCompositeSnapshot,
  key: LaneKey,
): string {
  switch (key) {
    case 'phase': return snapshot.phase
    case 'turn': return snapshot.turn_phase
    case 'decision': return snapshot.decision.stage
    case 'cascade': return snapshot.cascade.state
    case 'compaction': return snapshot.compaction.stage
    case 'breaker': return snapshot.circuit_breaker?.state ?? 'clean'
  }
}

export type TopTransition = {
  field: string
  from: string
  to: string
  count: number
}

export type DwellEntry = {
  value: string
  seconds: number
  pct: number
}

export type LaneDwell = {
  field: string
  laneKey: LaneKey
  totalSeconds: number
  entries: DwellEntry[]
}

export type InsightTone = 'ok' | 'info' | 'warn' | 'error'

export type OperationalInsight = {
  tone: InsightTone
  headline: string
  detail: string
  nextStep: string
  evidence: string[]
}

export type ObservedLaneSummary = {
  field: string
  label: string
  value: string
  tone: InsightTone
  stalled: boolean
  meaning: string
  observedForSec: number
  transitionCount: number
}

export type InvariantViolationCounts = Record<keyof KeeperCompositeInvariants, number>

export type HubState = {
  keeperName: string | null
  snapshot: KeeperCompositeSnapshot | null
  loading: boolean
  error: string | null
  lastFetchAt: number
  observations: CompositeObservation[]
  invariantSampleCount: number
  invariantViolations: InvariantViolationCounts
}

export type HubAction =
  | { type: 'fetch_started'; keeperName: string }
  | { type: 'fetch_succeeded'; keeperName: string; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { type: 'fetch_failed'; keeperName: string; error: string }

export const MAX_OBSERVATIONS = 30
export const MAX_TRANSITION_HISTORY = 20

const ZERO_VIOLATIONS: InvariantViolationCounts = {
  phase_turn_alignment: 0,
  no_cascade_before_measurement: 0,
  compaction_atomicity: 0,
  event_priority_monotone: 0,
  phase_derivation_agreement: 0,
}

export const initialHubState: HubState = {
  keeperName: null,
  snapshot: null,
  loading: false,
  error: null,
  lastFetchAt: 0,
  observations: [],
  invariantSampleCount: 0,
  invariantViolations: { ...ZERO_VIOLATIONS },
}

export const TRANSITION_FIELDS: Array<{ field: string; key: LaneKey }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'cascade' },
  { field: 'KMC', key: 'compaction' },
  { field: 'KCB', key: 'breaker' },
]

export const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: '단계 ⇔ 턴',
  no_cascade_before_measurement: 'Cascade 순서',
  compaction_atomicity: '압축 원자성',
  event_priority_monotone: '이벤트 우선순위',
  phase_derivation_agreement: 'Phase 유도 일치',
}

export const LANE_LABELS: Record<LaneKey, string> = {
  phase: 'Keeper 생명주기',
  turn: '턴 주기',
  decision: '의사결정',
  cascade: '캐스케이드',
  compaction: '컨텍스트 압축',
  breaker: '서킷 브레이커',
}

/** Korean display names for raw FSM state values.
    Replaces English internals in PipelineStep and Swimlane. */
export const STATE_DISPLAY_NAMES: Record<string, string> = {
  // KTC (unique keys — shared keys like idle/exhausted moved below)
  prompting: '프롬프트 구성',
  routing: '라우팅',
  executing: '실행 중',
  finalizing: '마무리',
  // KDP
  undecided: '대기',
  guard_ok: '가드 통과',
  gate_rejected: '게이트 거부',
  tool_policy_selected: '도구 목록 적용',
  // KCL + shared keys (idle, exhausted, compacting, done)
  idle: '대기',
  selecting: '선택 중',
  trying: '시도 중',
  done: '완료',
  exhausted: '소진',
  compacting: '압축 중',
  // KMC
  accumulating: '수집 중',
  // KCB (LT-16-KCB Phase 3) — circuit breaker display states emitted by
  // `Keeper_failure_circuit_breaker.display_state_to_string`
  // (lib/keeper/keeper_failure_circuit_breaker.ml:438):
  // clean | warning | cooling. The lane is consumed via
  // `extractLaneValue` (line 30) and the per-keeper KCB badge added in
  // #16365. Without these entries the Korean facade falls through to
  // raw English so operators see `KCB clean` while every other axis
  // renders Korean.
  clean: '정상',
  warning: '경고',
  cooling: '냉각 중',
  // KSM
  running: '가동 중',
  failing: '오류 발생',
  overflowed: '컨텍스트 초과',
  handing_off: '인수인계',
  draining: '종료 준비',
  offline: '오프라인',
  paused: '일시 중지',
  stopped: '정지',
  crashed: '비정상 종료',
  restarting: '재시작 중',
  dead: '종료됨',
  zombie: '좀비',
  Running: '가동 중',
  Overflowed: '컨텍스트 초과',
  Compacting: '압축 중',
  HandingOff: '인수인계',
  Failing: '오류 발생',
  Crashed: '비정상 종료',
  Offline: '오프라인',
  Paused: '일시 중지',
  Stopped: '정지',
  Draining: '종료 준비',
  Restarting: '재시작 중',
  Dead: '종료됨',
  Zombie: '좀비',
}

/** Resolve display name: Korean label for UI, raw value preserved in tooltips. */
export function displayState(value: string): string {
  return STATE_DISPLAY_NAMES[value] ?? value
}

/** Korean labels for `last_failure_reason` cohort bases. Backend emits
 *  the value via `Keeper_registry_types.failure_reason_to_string`
 *  (lib/keeper/keeper_registry_types.ml:104-135) in the parametric
 *  format `<base>(<detail>)` (e.g. `heartbeat_consecutive_failures(3)`,
 *  `tool_required_unsatisfied(code:detail)`). The 11 closed-sum bases
 *  match the `failure_reason_to_string` base prefixes (line 104-135).
 *  Note: `failure_reason_cohort_key` (line 146-159) uses shortened
 *  keys (`heartbeat_failures`, `turn_failures`) for metric grouping
 *  and is NOT the wire format. Helper splits the
 *  raw string at the first `(`, maps the base to Korean, and reattaches
 *  the `(detail)` portion verbatim so operators retain the parametric
 *  payload while reading a Korean label. Unknown bases fall back to
 *  the raw string. */
const FAILURE_REASON_BASE_LABELS: Record<string, string> = {
  heartbeat_consecutive_failures: '하트비트 연속 실패',
  turn_consecutive_failures: '턴 연속 실패',
  stale_turn_timeout: 'Stale 턴 시간 초과',
  stale_termination_storm: 'Stale 종료 폭주',
  stale_fleet_batch: 'Fleet stale 배치',
  oas_timeout_budget_loop: 'OAS 타임아웃 예산 루프',
  provider_runtime_error: 'Provider 런타임 오류',
  tool_required_unsatisfied: '필수 도구 미충족',
  ambiguous_partial_commit: '부분 commit 모호',
  fiber_unresolved: 'Fiber 미해결',
  exception: '런타임 예외',
}

export function failureReasonLabel(value: string | null | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim()
  if (!trimmed) return null
  const parenIdx = trimmed.indexOf('(')
  const base = parenIdx >= 0 ? trimmed.slice(0, parenIdx) : trimmed
  const koreanBase = FAILURE_REASON_BASE_LABELS[base]
  if (!koreanBase) return trimmed
  return parenIdx >= 0 ? `${koreanBase}${trimmed.slice(parenIdx)}` : koreanBase
}

/** Korean labels for `execution.outcome` / `keeper.latest_execution_outcome`.
 *  Backend emits the TLA-prefix form via
 *  `Keeper_execution_receipt.outcome_kind_to_tla_receipt`
 *  (lib/keeper/keeper_execution_receipt.ml:24-29):
 *  receipt_done / receipt_skipped / receipt_failed / receipt_cancelled.
 *  The TLA spec ReceiptIsAuthoritative invariant
 *  (keeper_execution_receipt.ml:54-58) fixes this canonical form.
 *  Kept separate from `STATE_DISPLAY_NAMES` so generic short tokens
 *  do not collide; the prefix makes collisions unlikely but the
 *  per-axis helper pattern (#16374, #16377, #16380, #16382, #16388,
 *  #16396) is the established discipline. */
const EXECUTION_OUTCOME_LABELS: Record<string, string> = {
  receipt_done: '완료',
  receipt_skipped: '건너뜀',
  receipt_failed: '실패',
  receipt_cancelled: '취소됨',
}

export function executionOutcomeLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return EXECUTION_OUTCOME_LABELS[value] ?? value
}


/** Korean labels for the three tool-surface axes emitted by
 *  `lib/keeper/keeper_agent_tool_surface.ml`:
 *  - `tool_requirement` (3 values, line 24-27):
 *    required / optional / none.
 *  - `tool_surface_class` (3 values, line 103-107, RFC-0065 §3.2.2):
 *    none / public_only / mixed.
 *  - `turn_lane` (6 values, line 57-63):
 *    pre_dispatch / text_only / tool_required / tool_optional /
 *    tool_disabled / retry.
 *  Tooltips in `fsm-hub.ts:159-160` and stale-cause parts list in
 *  `fleet-fsm-matrix.ts:289-295` currently interpolate these as raw
 *  English tokens. Each helper keeps the raw token as fallback so a
 *  backend-ahead variant still surfaces verbatim. */
const TOOL_REQUIREMENT_LABELS: Record<string, string> = {
  required: '필수',
  optional: '선택',
  none: '없음',
}

const TOOL_SURFACE_CLASS_LABELS: Record<string, string> = {
  none: '도구 없음',
  public_only: '공개 도구만',
  mixed: '혼합 도구',
}

const TURN_LANE_LABELS: Record<string, string> = {
  pre_dispatch: '디스패치 전',
  text_only: '텍스트 전용',
  tool_required: '도구 필수',
  tool_optional: '도구 선택',
  tool_disabled: '도구 비활성',
  retry: '재시도',
}

export function toolRequirementLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TOOL_REQUIREMENT_LABELS[value] ?? value
}

export function toolSurfaceClassLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TOOL_SURFACE_CLASS_LABELS[value] ?? value
}

export function turnLaneLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TURN_LANE_LABELS[value] ?? value
}

/** Korean labels for `trust.disposition`. Backend emits 4 closed-sum
 *  values via `display_disposition_of_operator`
 *  (lib/keeper/keeper_runtime_trust_snapshot.ml:687-697):
 *  Alert / Blocked / Pause / Pass. Kept separate from
 *  `STATE_DISPLAY_NAMES` to avoid collision on generic PascalCase
 *  tokens that other axes also emit. Two prior inline copies of this
 *  map (`keeper-detail-alert-strip.ts:201-205` and
 *  `goals/goal-tree.ts:194-199`) were identical 4-entry literals —
 *  consolidating here closes the duplicate-definition surface in the
 *  same spirit as #16343 (5th invariant grid). */
const TRUST_DISPOSITION_LABELS: Record<string, string> = {
  Alert: '경보',
  Blocked: '차단',
  Pause: '정지',
  Pass: '통과',
}

export function trustDispositionLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TRUST_DISPOSITION_LABELS[value] ?? value
}


/** Korean labels for `execution.tool_contract_result`. Backend emits 11
 *  closed-sum values via `Keeper_execution_receipt.tool_contract_result_to_string`
 *  (lib/keeper/keeper_execution_receipt.ml:181-193). The labels are
 *  intentionally NOT folded into `STATE_DISPLAY_NAMES` because that map
 *  is the shared FSM-axis facade and accepting generic keys like
 *  `unknown` / `violated` there would risk collisions with future axes
 *  that emit the same English token. Consumers route through
 *  {!toolContractLabel} instead so the chip surface (turn-fsm-detail-panel,
 *  fleet-fsm-matrix) shows Korean for known wire values and the raw
 *  token for unknown ones, matching the `displayState` fallback shape. */
const TOOL_CONTRACT_LABELS: Record<string, string> = {
  unknown: '도구 계약 미상',
  not_dispatched: '도구 호출 미발생',
  violated: '도구 계약 위반',
  tool_surface_mismatch: '도구 표면 불일치',
  no_tool_capable_provider: '도구 가능 provider 없음',
  missing_required_tool_use: '필수 도구 호출 누락',
  claim_only_after_owned_task: 'claim 전용 (소유 task 후)',
  needs_execution_progress: '실행 진척 필요',
  passive_only: 'passive 만 수행',
  satisfied_completion: '계약 충족 (완료)',
  satisfied_execution: '계약 충족 (실행)',
}

export function toolContractLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TOOL_CONTRACT_LABELS[value] ?? value
}



/** Korean labels for `execution.operator_disposition`. Backend emits 8
 *  closed-sum values via
 *  `Keeper_execution_receipt.operator_disposition_kind_to_string`
 *  (lib/keeper/keeper_execution_receipt.ml:401-410). Kept separate
 *  from `STATE_DISPLAY_NAMES` to avoid collision on generic tokens
 *  like `unknown` / `skipped` that other axes also emit. */
const OPERATOR_DISPOSITION_LABELS: Record<string, string> = {
  pass: '진행',
  pause_human: '운영자 일시정지',
  alert_exhausted: '경보 소진',
  fail_open_next_cascade: '다음 cascade 로 fail-open',
  pass_next_model: '다음 모델로 진행',
  user_cancelled: '사용자 취소',
  skipped: '건너뜀',
  unknown: '미상',
}

export function operatorDispositionLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return OPERATOR_DISPOSITION_LABELS[value] ?? value
}

/** Korean labels for `execution.operator_disposition_reason`. Backend
 *  emits 13 closed-sum values via
 *  `Keeper_execution_receipt.operator_disposition_reason_to_string`
 *  (lib/keeper/keeper_execution_receipt.ml:427-441). Paired with
 *  {!operatorDispositionLabel} at every emit site — same atomic
 *  coverage as the attention_reason / next_human_action pair fixed
 *  by #16355. */
const OPERATOR_DISPOSITION_REASON_LABELS: Record<string, string> = {
  healthy: '정상',
  cascade_exhausted: '캐스케이드 소진',
  preflight_config_error: '실행 전 설정 오류',
  degraded_retry: '저하 상태 재시도',
  cascade_fallback: '캐스케이드 폴백',
  provider_runtime_error: 'Provider 런타임 오류',
  internal_error: '내부 오류',
  tool_required_unsatisfied: '필수 도구 미충족',
  tool_route_recoverable_failure: '도구 라우팅 복구 가능 실패',
  turn_livelock_blocked: '턴 livelock 차단',
  cancelled: '취소됨',
  phase_skipped: 'phase 건너뜀',
  unmapped_cascade_state: '매핑되지 않은 cascade 상태',
}

export function operatorDispositionReasonLabel(
  value: string | null | undefined,
): string | null {
  if (!value) return null
  return OPERATOR_DISPOSITION_REASON_LABELS[value] ?? value
}

/** Korean labels for `execution.cascade.outcome` /
 *  `keeper.cascade_outcome`. Backend emits 4 closed-sum values via
 *  `Keeper_execution_receipt.cascade_outcome_to_string`
 *  (lib/keeper/keeper_execution_receipt.ml:144-149). Kept separate
 *  from `STATE_DISPLAY_NAMES` because `completed` and
 *  `not_observed` are generic tokens other axes may emit (same
 *  isolation pattern as TOOL_CONTRACT_LABELS in #16374 and
 *  OPERATOR_DISPOSITION_LABELS in #16377). */
const CASCADE_OUTCOME_LABELS: Record<string, string> = {
  passed_to_next_model: '다음 모델로 진행',
  completed: '완료',
  not_observed: '관측되지 않음',
  not_dispatched: '디스패치 안 됨',
}

export function cascadeOutcomeLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return CASCADE_OUTCOME_LABELS[value] ?? value
}

export type StateEntries = {
  phase: number
  turn: number
  decision: number
  cascade: number
  compaction: number
}

export type TimeAxisTick = { ts: number; label: string }

export type SwimlaneSegment = {
  from: number
  to: number
  value: string
}

/** Cross-panel hover coordination payload. When a swimlane segment is
    under the cursor, the SwimlaneTimeline publishes which lane, value,
    and time window it covers, and downstream panels (TransitionTrail,
    PipelineStep) highlight rows that overlap. */
export type HoveredSegment = {
  field: string  // KSM / KTC / KDP / KCL / KMC
  laneKey: LaneKey
  from: number
  to: number
  value: string
}

export function fmtDuration(seconds: number): string {
  if (seconds < 0) return '0s'
  const s = Math.floor(seconds)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  const rem = s % 60
  if (m < 60) return `${m}m ${rem}s`
  const h = Math.floor(m / 60)
  return `${h}h ${m % 60}m`
}
