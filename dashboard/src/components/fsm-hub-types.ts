import type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
} from '../api/schemas/keeper-composite'

export type CompositeObservation = {
  ts: number
  phase: KeeperCompositeSnapshot['phase']
  turn: KeeperCompositeSnapshot['turn_phase']
  decision: KeeperCompositeSnapshot['decision']['stage']
  runtime: KeeperCompositeSnapshot['runtime']['state']
  compaction: KeeperCompositeSnapshot['compaction']['stage']
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
    case 'runtime': return snapshot.runtime.state
    case 'compaction': return snapshot.compaction.stage
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

/** Discriminated union for the composite snapshot's fetch state. The
 *  prior shape conflated success and failure by keeping `snapshot`
 *  populated after `fetch_failed` (Workaround Rejection Bar §2).
 *  Consumers must now `switch (status.kind)` to read the snapshot —
 *  stale data is only visible when explicitly accepted on the
 *  `'stale'` arm. The `idle` arm represents "no keeper selected yet". */
export type HubFetchStatus =
  | { kind: 'idle' }
  | { kind: 'loading' }
  | { kind: 'fresh'; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { kind: 'stale'; snapshot: KeeperCompositeSnapshot; fetchedAt: number; stalenessMs: number; error: string }
  | { kind: 'error'; error: string }

export type HubState = {
  keeperName: string | null
  status: HubFetchStatus
  observations: CompositeObservation[]
  invariantSampleCount: number
  invariantViolations: InvariantViolationCounts
}

export type HubAction =
  | { type: 'fetch_started'; keeperName: string }
  | { type: 'fetch_succeeded'; keeperName: string; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { type: 'fetch_failed'; keeperName: string; error: string; failedAt: number }

export const MAX_OBSERVATIONS = 30
export const MAX_TRANSITION_HISTORY = 20

const ZERO_VIOLATIONS: InvariantViolationCounts = {
  phase_turn_alignment: 0,
  no_runtime_before_measurement: 0,
  compaction_atomicity: 0,
  event_priority_monotone: 0,
  phase_derivation_agreement: 0,
}

export const initialHubState: HubState = {
  keeperName: null,
  status: { kind: 'idle' },
  observations: [],
  invariantSampleCount: 0,
  invariantViolations: { ...ZERO_VIOLATIONS },
}

/** Returns the snapshot only when status is `'fresh'`. Stale/error/
 *  loading/idle collapse to `null`. Consumers that want stale data
 *  must `switch` on `status.kind` directly and show a staleness
 *  banner. */
export function hubFreshSnapshot(status: HubFetchStatus): KeeperCompositeSnapshot | null {
  switch (status.kind) {
    case 'fresh':
      return status.snapshot
    case 'stale':
    case 'idle':
    case 'loading':
    case 'error':
      return null
  }
}

export const TRANSITION_FIELDS: Array<{ field: string; key: LaneKey }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'runtime' },
  { field: 'KMC', key: 'compaction' },
]

export const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: '단계 ⇔ 턴',
  no_runtime_before_measurement: 'Runtime 순서',
  compaction_atomicity: '압축 원자성',
  event_priority_monotone: '이벤트 우선순위',
  phase_derivation_agreement: 'Phase 유도 일치',
}

export const LANE_LABELS: Record<LaneKey, string> = {
  phase: 'Keeper 생명주기',
  turn: '턴 주기',
  decision: '의사결정',
  runtime: '런타임',
  compaction: '컨텍스트 압축',
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
  // KSM
  running: '가동 중',
  failing: '오류 발생',
  overflowed: '컨텍스트 초과',
  handing_off: '인수인계',
  draining: '종료 준비',
  offline: '오프라인',
  paused: '일시정지',
  stopped: '정지',
  crashed: '비정상 종료',
  restarting: '재시작 중',
  dead: '종료됨',
  Running: '가동 중',
  Overflowed: '컨텍스트 초과',
  Compacting: '압축 중',
  HandingOff: '인수인계',
  Failing: '오류 발생',
  Crashed: '비정상 종료',
  Offline: '오프라인',
  Paused: '일시정지',
  Stopped: '정지',
  Draining: '종료 준비',
  Restarting: '재시작 중',
  Dead: '종료됨',
}

/** Resolve display name: Korean label for UI, raw value preserved in tooltips. */
export function displayState(value: string): string {
  return STATE_DISPLAY_NAMES[value] ?? value
}

/** Korean labels for `last_failure_reason` cohort bases. Backend emits
 *  the value via `Keeper_registry_types.failure_reason_to_string`
 *  (lib/keeper/keeper_registry_types.ml:104-135) in the parametric
 *  format `<base>(<detail>)` (e.g. `heartbeat_consecutive_failures(3)`).
 *  The closed-sum bases
 *  match the `failure_reason_to_string` base prefixes (line 104-135).
 *  Note: `failure_reason_cohort_key` (line 146-159) uses shortened
 *  keys (`heartbeat_failures`, `turn_failures`) for metric grouping
 *  and is NOT the wire format. Helper splits the
 *  raw string at the first `(`, maps the base to Korean, and reattaches
 *  the `(detail)` portion verbatim so operators retain the parametric
 *  payload while reading a Korean label. Unknown bases fall back to
 *  the raw string. */
const FAILURE_REASON_BASE_LABELS = {
  heartbeat_consecutive_failures: '하트비트 연속 실패',
  turn_consecutive_failures: '턴 연속 실패',
  stale_turn_timeout: 'Stale 턴 시간 초과',
  stale_termination_storm: 'Stale 종료 폭주',
  stale_fleet_batch: 'Fleet stale 배치',
  provider_runtime_error: '런타임 호출 오류',
  fiber_unresolved: 'Fiber 미해결',
  exception: '런타임 예외',
} as const

type FailureReasonBase = keyof typeof FAILURE_REASON_BASE_LABELS

function isFailureReasonBase(value: string): value is FailureReasonBase {
  return Object.prototype.hasOwnProperty.call(FAILURE_REASON_BASE_LABELS, value)
}

/** Split a parametric string `<base>(<detail>)` at the first '('.
 *  Returns `[base, detail]` where detail includes the '('.
 *  If no '(' is found, returns `[whole, null]`.
 *  Mirrors the backend wire format emitted by
 *  `Keeper_registry_types.failure_reason_to_string`. */
function splitParametric(value: string): [string, string | null] {
  const idx = value.indexOf('(')
  if (idx < 0) return [value, null]
  return [value.slice(0, idx), value.slice(idx)]
}

export function failureReasonLabel(value: string | null | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim()
  if (!trimmed) return null
  const [base, detail] = splitParametric(trimmed)
  if (!isFailureReasonBase(base)) return trimmed
  const koreanBase = FAILURE_REASON_BASE_LABELS[base]
  return detail ? `${koreanBase}${detail}` : koreanBase
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
  Pause: '일시정지',
  Pass: '통과',
}

export function trustDispositionLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return TRUST_DISPOSITION_LABELS[value] ?? value
}

/** Scope tag for runtime-outcome rendering.
 *
 *  `runtime_outcome` is emitted per-provider-attempt (the last hop in
 *  a runtime ladder), while `stop_cause` is emitted per-turn (the
 *  terminal verdict for the whole turn budget). Rendering the
 *  per-attempt success under the generic "런타임 레인" label next to
 *  a per-turn failure such as `turn_timeout` reads as a
 *  contradiction.
 *
 *  We tag the observation with an explicit scope (`attempt`) and gate
 *  the render when the per-turn stop cause classifies the turn as a
 *  terminal failure — the attempt-level success is still preserved
 *  inside the stop-cause line via the `code · summary` columns, just
 *  not re-rendered as a competing top-level lane. */
export type RuntimeAttemptScope = 'attempt' | 'turn'

export interface RuntimeAttemptObservation {
  scope: RuntimeAttemptScope
  outcome: string | null
  attempts: number | null
  fallbackApplied: boolean
}

/** Stop-cause codes that classify the turn as a terminal failure. When
 *  the turn is terminal-failed at the per-turn scope, a per-attempt
 *  `completed` outcome must not be rendered as a co-equal "런타임
 *  레인" badge — that is the second contradiction the strip used to
 *  surface. The list is derived from the runtime_blocker_class /
 *  terminal_reason_code closed-sums actually observed in
 *  `lib/keeper/keeper_status_bridge.ml` and
 *  `lib/keeper/keeper_runtime_trust_snapshot.ml`. Unknown codes do
 *  not gate (fail open: operator still sees the attempt outcome). */
const TURN_TERMINAL_FAILURE_CODES = new Set<string>([
  'turn_timeout',
  'turn_wall_clock_timeout',
  'runtime_exhausted',
  'heartbeat_consecutive_failures',
  'turn_consecutive_failures',
  'provider_runtime_error',
  'fiber_unresolved',
  'stale_turn_timeout',
])

export function isTurnTerminalFailureCode(code: string | null | undefined): boolean {
  if (!code) return false
  return TURN_TERMINAL_FAILURE_CODES.has(code)
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
  fail_open_next_runtime: '다음 runtime 로 fail-open',
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
 *  emits closed-sum values via
 *  `Keeper_execution_receipt.operator_disposition_reason_to_string`. Paired with
 *  {!operatorDispositionLabel} at every emit site — same atomic
 *  coverage as the attention_reason / next_human_action pair fixed
 *  by #16355. */
const OPERATOR_DISPOSITION_REASON_LABELS: Record<string, string> = {
  healthy: '정상',
  runtime_exhausted: '런타임 후보 소진',
  preflight_config_error: '실행 전 설정 오류',
  degraded_retry: '저하 상태 재시도',
  runtime_fallback: '런타임 폴백',
  transient_runtime_retry: '일시적 런타임 재시도',
  provider_runtime_error: '런타임 호출 오류',
  internal_error: '내부 오류',
  input_required: '사용자 입력 대기',
  turn_budget_exhausted: '턴 예산 소진',
  cancelled: '취소됨',
  phase_skipped: 'phase 건너뜀',
  unmapped_runtime_state: '매핑되지 않은 runtime 상태',
}

export function operatorDispositionReasonLabel(
  value: string | null | undefined,
): string | null {
  if (!value) return null
  return OPERATOR_DISPOSITION_REASON_LABELS[value] ?? value
}

/** Korean labels for `execution.runtime.outcome` /
 *  `keeper.runtime_outcome`. Backend emits 4 closed-sum values via
 *  `Keeper_execution_receipt.runtime_outcome_to_string`
 *  (lib/keeper/keeper_execution_receipt.ml:144-149). Kept separate
 *  from `STATE_DISPLAY_NAMES` because `completed` and
 *  `not_observed` are generic tokens other axes may emit (same
 *  isolation pattern as TOOL_CONTRACT_LABELS in #16374 and
 *  OPERATOR_DISPOSITION_LABELS in #16377). */
const RUNTIME_OUTCOME_LABELS: Record<string, string> = {
  passed_to_next_model: '다음 모델로 진행',
  completed: '완료',
  not_observed: '관측되지 않음',
  not_dispatched: '디스패치 안 됨',
}

export function runtimeOutcomeLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return RUNTIME_OUTCOME_LABELS[value] ?? value
}

/** Korean labels for `execution.terminal_reason_code`. Backend emits this
 *  across multiple paths:
 *  - `Keeper_turn_terminal_code.to_wire` (lib/keeper/keeper_turn_terminal_code.ml:28-50)
 *    emits 10 fixed wire values + parameterized `Provider_runtime_error`,
 *    `Tool_required_unsatisfied`, `Sdk_error` (which inject the raw `code`
 *    string straight onto the wire).
 *  - `Keeper_agent_error.to_terminal_reason_code` (lib/keeper/keeper_agent_error.ml:134-143)
 *    maps Agent SDK Retry variants to `api_error_*` codes
 *    (`api_error_server:<http_status>` is parameterized).
 *  - `Keeper_agent_run` emits `"completed"` on Runtime_runner.Completed.
 *  Kept separate from `STATE_DISPLAY_NAMES` because generic tokens like
 *  `completed` / `healthy` are also emitted by other axes (same isolation
 *  pattern as TOOL_CONTRACT_LABELS in #16374). Parameterized codes fall
 *  through to a prefix match below before the raw fallback. */
const TERMINAL_REASON_CODE_LABELS: Record<string, string> = {
  // Keeper_turn_terminal_code.to_wire
  healthy: '정상',
  stale_turn_timeout: '오래된 턴 시간 초과',
  stale_termination_storm: 'Stale 종료 폭주',
  stale_fleet_batch: 'Fleet stale 배치',
  heartbeat_failures: '하트비트 실패',
  turn_failures: '턴 실패 반복',
  fiber_unresolved: 'Fiber 미해결',
  exception: '런타임 예외',
  // Keeper_agent_run completion
  completed: '완료',
  // Keeper_agent_error Retry → api_error_*
  api_error_rate_limited: 'API rate-limit',
  api_error_overloaded: 'API 과부하',
  api_error_auth: 'API 인증 오류',
  api_error_invalid_request: 'API 잘못된 요청',
  api_error_not_found: 'API 자원 없음',
  api_error_context_overflow: 'API 컨텍스트 초과',
  api_error_network: 'API 네트워크 오류',
  api_error_timeout: 'API 타임아웃',
  // keeper_unified_turn.ml:210
  registry_phase_missing: '레지스트리 phase 누락',
}

// Parameterized-prefix lookup for terminal reason codes that carry
// a dynamic suffix after a colon (e.g. `api_error_server:503`).
// The prefix is the known part; the suffix is opaque detail.
const TERMINAL_REASON_PREFIX_LABELS: ReadonlyArray<{
  readonly prefix: string
  readonly label: string
}> = [
  { prefix: 'api_error_server:', label: 'API 서버 오류' },
]

export function terminalReasonCodeLabel(value: string | null | undefined): string | null {
  if (!value) return null
  const exact = TERMINAL_REASON_CODE_LABELS[value]
  if (exact) return exact
  for (const { prefix, label } of TERMINAL_REASON_PREFIX_LABELS) {
    if (value.startsWith(prefix)) return label
  }
  return value
}

export type StateEntries = {
  phase: number
  turn: number
  decision: number
  runtime: number
  compaction: number
}

export type TimeAxisTick = { ts: number; label: string }

export type SwimlaneSegment = {
  from: number
  to: number
  value: string
}

/** Cross-panel hover workspace payload. When a swimlane segment is
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
