// Pure Keeper FSM label, invariant, and swimlane derivation helpers.

import type { KeeperCompositeSnapshot, KeeperCompositeInvariants } from '../api/schemas/keeper-composite'
import { PHASE_LABEL_KO } from './fleet-tone'
import { asKeeperRuntimeBlockerClass } from './runtime-blocker-class'
import { unixSecondsToDate } from './format-time'
import type { KeeperRuntimeBlockerClass, TrustDisposition } from '../types'

export type CompositeObservation = {
  ts: number
  phase: KeeperCompositeSnapshot['phase']
  turn: KeeperCompositeSnapshot['turn_phase']
  decision: KeeperCompositeSnapshot['decision']['stage']
  runtime: KeeperCompositeSnapshot['runtime']['state']
}

export type LaneKey = keyof Omit<CompositeObservation, 'ts'>

export type SwimlaneSegment = {
  from: number
  to: number
  value: string
}

export type TimeAxisTick = { ts: number; label: string }

export const MAX_OBSERVATIONS = 30

export const TRANSITION_FIELDS: Array<{ field: string; key: LaneKey }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'runtime' },
]

export const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  event_priority_monotone: 'Measurement 소유권',
  phase_derivation_agreement: 'Phase 유도 일치',
}

export const LANE_LABELS: Record<LaneKey, string> = {
  phase: 'Keeper 생명주기',
  turn: '턴 주기',
  decision: '의사결정',
  runtime: '런타임',
}

export const STATE_DISPLAY_NAMES: Record<string, string> = {
  prompting: '프롬프트 구성',
  routing: '라우팅',
  executing: '실행 중',
  finalizing: '마무리',
  undecided: '대기',
  guard_ok: '가드 통과',
  tool_policy_selected: '도구 목록 적용',
  idle: '대기',
  done: '완료',
  exhausted: '소진',
  running: PHASE_LABEL_KO.running,
  failing: PHASE_LABEL_KO.failing,
  draining: PHASE_LABEL_KO.draining,
  offline: '오프라인',
  paused: PHASE_LABEL_KO.paused,
  stopped: PHASE_LABEL_KO.stopped,
  crashed: PHASE_LABEL_KO.crashed,
  restarting: PHASE_LABEL_KO.restarting,
  Running: PHASE_LABEL_KO.running,
  Failing: PHASE_LABEL_KO.failing,
  Crashed: PHASE_LABEL_KO.crashed,
  Offline: '오프라인',
  Paused: PHASE_LABEL_KO.paused,
  Stopped: PHASE_LABEL_KO.stopped,
  Draining: PHASE_LABEL_KO.draining,
  Restarting: PHASE_LABEL_KO.restarting,
}

export function displayState(value: string): string {
  return STATE_DISPLAY_NAMES[value] ?? value
}

const FAILURE_REASON_BASE_LABELS = {
  heartbeat_consecutive_failures: '하트비트 연속 실패',
  turn_consecutive_failures: '턴 연속 실패',
  provider_runtime_error: '런타임 호출 오류',
  fiber_unresolved: 'Fiber 미해결',
  exception: '런타임 예외',
} as const

type FailureReasonBase = keyof typeof FAILURE_REASON_BASE_LABELS

function isFailureReasonBase(value: string): value is FailureReasonBase {
  return Object.prototype.hasOwnProperty.call(FAILURE_REASON_BASE_LABELS, value)
}

export function failureReasonLabel(value: string | null | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim()
  if (!trimmed) return null
  const idx = trimmed.indexOf('(')
  const base = idx < 0 ? trimmed : trimmed.slice(0, idx)
  const detail = idx < 0 ? null : trimmed.slice(idx)
  if (!isFailureReasonBase(base)) return trimmed
  const koreanBase = FAILURE_REASON_BASE_LABELS[base]
  return detail ? `${koreanBase}${detail}` : koreanBase
}

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

const TRUST_DISPOSITION_LABELS: Record<TrustDisposition, string> = {
  Pass: '통과',
  Alert: '경보',
  Blocked: '차단',
  Degraded: '확인 불가',
}

export type RuntimeAttemptScope = 'attempt' | 'turn'

export interface RuntimeAttemptObservation {
  scope: RuntimeAttemptScope
  outcome: string | null
  attempts: number | null
  fallbackApplied: boolean
}

export function trustDispositionLabel(value: TrustDisposition | null | undefined): string | null {
  return value ? TRUST_DISPOSITION_LABELS[value] : null
}

const RUNTIME_BLOCKER_TURN_TERMINAL_FAILURE = {
  heartbeat_failures: true,
  turn_failures: true,
  runtime_exhausted: true,
  provider_runtime_error: true,
  official_client_recovery_required: true,
  turn_configuration_error: true,
  fiber_unresolved: true,
  exception: true,
  operator_interrupt: false,
} satisfies Record<KeeperRuntimeBlockerClass, boolean>

const TERMINAL_REASON_FAILURE_CODES: ReadonlySet<string> = new Set([
  'provider_attempt_effect_fenced',
])

export function isTurnTerminalFailureCode(code: string | null | undefined): boolean {
  const blockerClass = asKeeperRuntimeBlockerClass(code)
  if (blockerClass !== null) return RUNTIME_BLOCKER_TURN_TERMINAL_FAILURE[blockerClass]
  return typeof code === 'string' && TERMINAL_REASON_FAILURE_CODES.has(code)
}

export const OPERATOR_DISPOSITION_REASONS = [
  'healthy',
  'runtime_exhausted',
  'config_invalid',
  'authorization_refused',
  'degraded_retry',
  'runtime_fallback',
  'transient_runtime_retry',
  'provider_runtime_error',
  'internal_error',
  'input_required',
  'cancelled',
  'phase_skipped',
  'transcript_corruption',
  'official_client_recovery_required',
  'official_client_session_refused',
  'provider_attempt_effect_fenced',
  'tool_correction_lost',
  'accept_rejected',
  'terminal_effect_failed',
  'unmapped_runtime_state',
] as const

export type OperatorDispositionReason = (typeof OPERATOR_DISPOSITION_REASONS)[number]

const OPERATOR_DISPOSITION_REASON_SET: ReadonlySet<string> = new Set(OPERATOR_DISPOSITION_REASONS)

const OPERATOR_DISPOSITION_REASON_LABELS = {
  healthy: '정상',
  runtime_exhausted: '런타임 후보 소진',
  config_invalid: '실행 전 설정 오류 - toml 을 고쳐야 함',
  authorization_refused: '제공자가 거절함 - 대개 사용량 한도, 슬롯을 옮겨야 함',
  degraded_retry: '저하 상태 재시도',
  runtime_fallback: '런타임 폴백',
  transient_runtime_retry: '일시적 런타임 재시도',
  provider_runtime_error: '런타임 호출 오류',
  internal_error: '내부 오류',
  input_required: '사용자 입력 대기',
  cancelled: '취소됨',
  phase_skipped: 'phase 건너뜀',
  transcript_corruption: '도구 호출 기록이 깨짐 - checkpoint purge 로 고쳐야 함',
  official_client_recovery_required: '공식 클라이언트 세션 복구 필요',
  official_client_session_refused: '공식 클라이언트 세션 상태로 거절 - 종료 코드에 이유가 있음',
  provider_attempt_effect_fenced: 'Provider 효과 결과 확인 필요',
  tool_correction_lost: '도구 교정 유실 - 거절 응답이 전달되지 못함',
  accept_rejected: '응답에 쓸 내용이 없어 거절 - 출력 예산 확인',
  terminal_effect_failed: '턴을 닫는 도구가 실패 - 결과가 나갔는지 불명',
  unmapped_runtime_state: '매핑되지 않은 runtime 상태',
} satisfies Record<OperatorDispositionReason, string>

export function operatorDispositionReasonLabel(value: string | null | undefined): string | null {
  if (!value) return null
  return OPERATOR_DISPOSITION_REASON_SET.has(value)
    ? OPERATOR_DISPOSITION_REASON_LABELS[value as OperatorDispositionReason]
    : value
}

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

const TERMINAL_REASON_CODE_LABELS: Record<string, string> = {
  healthy: '정상',
  heartbeat_failures: '하트비트 실패',
  turn_failures: '턴 실패 반복',
  fiber_unresolved: 'Fiber 미해결',
  exception: '런타임 예외',
  completed: '완료',
  api_error_rate_limited: 'API rate-limit',
  api_error_overloaded: 'API 과부하',
  api_error_auth: 'API 인증 오류',
  api_error_invalid_request: 'API 잘못된 요청',
  api_error_not_found: 'API 자원 없음',
  api_error_context_overflow: 'API 컨텍스트 초과',
  api_error_network: 'API 네트워크 오류',
  api_error_connect_failed: 'API 연결 실패',
  api_error_timeout: 'API 타임아웃',
  registry_phase_missing: '레지스트리 phase 누락',
}

export function terminalReasonCodeLabel(value: string | null | undefined): string | null {
  if (!value) return null
  const exact = TERMINAL_REASON_CODE_LABELS[value]
  if (exact) return exact
  if (value.startsWith('api_error_server:')) return 'API 서버 오류'
  return value
}

export function isObservedStall(key: LaneKey, value: string, observedForSec: number): boolean {
  if (key === 'phase') {
    if (value === 'failing') return observedForSec >= 90
    if (value === 'draining') return observedForSec >= 60
    return false
  }
  if (key === 'turn') {
    if (value === 'prompting' || value === 'executing') return observedForSec >= 45
    if (value === 'finalizing') return observedForSec >= 30
    return false
  }
  return false
}

export function observeSnapshot(snapshot: KeeperCompositeSnapshot, ts: number): CompositeObservation {
  return {
    ts,
    phase: snapshot.phase,
    turn: snapshot.turn_phase,
    decision: snapshot.decision.stage,
    runtime: snapshot.runtime.state,
  }
}

export function appendCompositeObservation(
  observations: CompositeObservation[],
  next: CompositeObservation,
  maxEntries = MAX_OBSERVATIONS,
): CompositeObservation[] {
  const last = observations[observations.length - 1]
  if (
    last
    && last.phase === next.phase
    && last.turn === next.turn
    && last.decision === next.decision
    && last.runtime === next.runtime
  ) {
    return observations
  }
  return [...observations, next].slice(-Math.max(1, maxEntries))
}

export function laneChangedAt(observations: CompositeObservation[], key: LaneKey): number {
  const last = observations[observations.length - 1]
  if (!last) return 0
  for (let index = observations.length - 1; index > 0; index -= 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    if (prev[key] !== next[key]) return next.ts
  }
  return observations[0]?.ts ?? last.ts
}

export function laneTransitionCount(observations: CompositeObservation[], key: LaneKey): number {
  let count = 0
  for (let index = 1; index < observations.length; index += 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    if (prev[key] !== next[key]) count += 1
  }
  return count
}

export function deriveSwimlaneSegments(
  observations: CompositeObservation[],
  key: LaneKey,
  boundsEnd: number,
): SwimlaneSegment[] {
  if (observations.length === 0) return []
  const segments: SwimlaneSegment[] = []
  for (const current of observations) {
    const last = segments[segments.length - 1]
    if (last && last.value === current[key]) {
      last.to = current.ts
    } else {
      if (last) last.to = current.ts
      segments.push({ from: current.ts, to: current.ts, value: current[key] })
    }
  }
  const tail = segments[segments.length - 1]
  if (tail && boundsEnd > tail.to) tail.to = boundsEnd
  return segments
}

const TIME_AXIS_STEPS_SEC = [1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200]

export function deriveTimeAxisTicks(spanStart: number, spanEnd: number, maxTicks = 6): TimeAxisTick[] {
  const span = spanEnd - spanStart
  if (span <= 0 || maxTicks < 2) return []
  const desiredStep = span / Math.max(1, maxTicks - 1)
  const step = TIME_AXIS_STEPS_SEC.find(s => s >= desiredStep) ?? TIME_AXIS_STEPS_SEC[TIME_AXIS_STEPS_SEC.length - 1] ?? desiredStep
  const showSeconds = step < 60
  const formatter = new Intl.DateTimeFormat(undefined, {
    hour: '2-digit',
    minute: '2-digit',
    ...(showSeconds ? { second: '2-digit' } : {}),
    hour12: false,
  })
  const firstTick = Math.ceil(spanStart / step) * step
  const ticks: TimeAxisTick[] = []
  for (let ts = firstTick; ts <= spanEnd && ticks.length < maxTicks; ts += step) {
    if (ts <= spanStart) continue
    ticks.push({ ts, label: formatter.format(unixSecondsToDate(ts)) })
  }
  return ticks
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
