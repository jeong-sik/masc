// Lane · Queue panel — pure derivations and presentation vocabulary for
// prototypes/keeper-v2/lanes.jsx, wired to live read models:
//
//   · 진행 타임라인 (sw-*)   — composite observations accumulated from the
//     fleet composite snapshot stream (`/api/v1/keepers/composite`, the same
//     payload fleet-fsm-matrix.ts consumes), run-length encoded per FSM lane.
//   · 무엇을 기다리는가 (pl-*/wa-*) — keeper_waiting_inventory.v3 via
//     src/keeper-waiting-inventory-store.ts (keeper-scoped authoritative read).
//   · 기동 · 재시작 기록 (lc-*) — /api/v1/keepers/:name/lifecycle events.
//   · 예약 실행 결과 (dl-*/dm-*) — scheduled-automation projection rows
//     carrying keeper_queue_evidence × keeper_reaction_evidence; the drain
//     verdict mirrors src/components/schedule/queue-drain-status.ts (SSOT for
//     the derivation — the parity test asserts the two never disagree).
//
// Value labels / stage pipeline / drain presentation copy reproduce the
// design's closed vocabularies verbatim (lanes.jsx VAL_LBL / LANE_SOURCE /
// STAGE / DRAIN_PRESENT). Where the design hard-codes mock duration series
// (LANE_TL), the panel derives segments from real observation timestamps and
// clips them to the same 20-minute window instead.

import type {
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
  DashboardScheduledAutomationRequest,
} from '../../api'
import type { KeeperLifecycleEvent } from '../../api/keeper'
import type { CompositeObservation, LaneKey, SwimlaneSegment } from '../fsm-hub-types'
import { isObservedStall } from '../fsm-hub-lane-analysis'
import { laneChangedAt, laneTransitionCount } from '../fsm-hub-derivations'
import { enumLabel } from '../tools/keeper-waiting-inventory-panel'
import type { QueueDrainState } from '../schedule/queue-drain-status'

/** Observation window of the swimlane, seconds (design WINDOW_S = 20분). */
export const LANE_QUEUE_WINDOW_S = 1200

/** Observation buffer depth per keeper. At the 30 s fleet poll cadence this
 *  covers the full 20-minute window plus one boundary sample. */
export const LANE_QUEUE_MAX_OBSERVATIONS = 41

const SECONDS_PER_MINUTE = 60
const HOUR_MINUTES = 60
const DAY_MINUTES = 24 * HOUR_MINUTES

/* ── 복합 FSM 레인 어휘 (design CL_LANES) ─────────────────────────────── */

export interface LaneQueueLaneDef {
  readonly key: LaneKey
  /** Technical (dev toggle) lane name. */
  readonly devLabel: string
  /** Operator lane name. */
  readonly label: string
  /** Wire field shown behind the dev toggle. */
  readonly field: string
}

export const LANE_QUEUE_LANES: readonly LaneQueueLaneDef[] = [
  { key: 'phase', devLabel: 'lifecycle', label: '생명주기', field: 'phase' },
  { key: 'turn', devLabel: 'turn-cycle', label: '턴 진행', field: 'turn_state' },
  { key: 'decision', devLabel: 'decision', label: '판단', field: 'decision_state' },
  { key: 'runtime', devLabel: 'runtime', label: '모델 호출', field: 'runtime_state' },
]

/** Design VAL_LBL — operator labels for the closed value vocabulary. */
const LANE_VALUE_LABELS: Record<string, string> = {
  running: '실행 중', failing: '문제 발생', draining: '정리 중',
  idle: '쉬는 중', prompting: '준비 중', executing: '작업 중', finalizing: '마무리', undecided: '미결정', guard_ok: '점검 통과',
  tool_policy_selected: '도구 확정', selecting: '경로 선택', trying: '모델 호출 중', done: '완료', exhausted: '가능한 경로 없음',
}

export function laneValueLabel(value: string): string {
  return LANE_VALUE_LABELS[value] ?? value
}

/** Design VAL_TONE — sw-seg data-tone values (lanes.css .sw-seg[data-tone]). */
export type LaneSegmentTone = 'ok' | 'info' | 'warn' | 'bad' | 'idle'

const LANE_VALUE_TONES: Record<string, LaneSegmentTone> = {
  running: 'info', failing: 'bad', draining: 'warn',
  idle: 'idle', prompting: 'info', executing: 'info', finalizing: 'info',
  undecided: 'idle', guard_ok: 'ok', tool_policy_selected: 'info',
  selecting: 'info', trying: 'info', done: 'ok', exhausted: 'bad',
}

export function laneValueTone(value: string): LaneSegmentTone {
  return LANE_VALUE_TONES[value] ?? 'info'
}

/** Design CL_MEANING — operator reading of the current lane value. `live`
 *  is the snapshot's is_live flag (진행 중인 턴 존재 여부). */
const LANE_MEANING: Record<LaneKey, Record<string, (live: boolean) => string>> = {
  phase: {
    running: (live) => live ? '정상 동작 중 — 지금 턴을 하나 돌리고 있다' : '정상 동작 중 — 지금 맡은 턴은 없다',
    failing: () => '문제가 걸려 있어 새 턴을 시작하지 못한다',
    draining: () => '남은 일을 마무리하고 멈추는 중',
  },
  turn: {
    idle: (live) => live ? '턴은 열려 있지만 지금 하는 일이 없다' : '지금 맡은 턴이 없다',
    prompting: () => '무엇을 할지 정리해 모델에 넘길 준비 중',
    executing: () => '모델을 부르거나 도구를 쓰는 중',
    finalizing: () => '결과를 저장하고 턴을 닫는 중',
  },
  decision: {
    undecided: (live) => live ? '아직 무엇을 할지 정하지 않았다' : '진행 중인 턴이 없어 정할 것도 없다',
    guard_ok: () => '안전 점검을 통과해 계속 진행할 수 있다',
    tool_policy_selected: () => '쓸 도구를 정했고 실행으로 넘어갈 수 있다',
  },
  runtime: {
    idle: () => '모델을 부르고 있지 않다',
    selecting: () => '어떤 모델로 부를지 고르는 중',
    trying: () => '모델 응답을 기다리는 중',
    done: () => '모델 응답을 받아 처리했다',
    exhausted: () => '쓸 수 있는 모델이 없다 — 사람이 손대야 한다',
  },
}

/** Design CL_MEANING_DEV — wire-level reading behind the 기술 상세 toggle. */
const LANE_MEANING_DEV: Record<LaneKey, Record<string, (live: boolean) => string>> = {
  phase: {
    running: (live) => live ? 'parent lifecycle 정상 — live turn 진행 중' : 'keeper 는 살아있고 진행 중인 turn 은 없음',
    failing: () => 'parent lifecycle degraded — healthy turn 재개 전 해소 필요',
    draining: () => 'in-flight work drain 중 (stop 전)',
  },
  turn: {
    idle: (live) => live ? 'turn context 존재하지만 work 미진행' : '진행 중인 turn 없음',
    prompting: () => 'prompt assembly 가 turn input 준비 중',
    executing: () => 'model/tool execution work 안에 있음',
    finalizing: () => '결과 seal + 다음 idle snapshot 준비 중',
  },
  decision: {
    undecided: (live) => live ? 'decision work 미커밋' : '진행 중인 turn 이 없어 결정 단계 없음',
    guard_ok: () => 'guardrail 통과 — turn 계속 진행 허용',
    tool_policy_selected: () => '도구 목록 선택 커밋됨 — execution 진행 가능',
  },
  runtime: {
    idle: () => 'provider/runtime 실행 중 아님',
    selecting: () => 'provider routing 이 다음 execution path 선택 중',
    trying: () => 'provider execution 진행 중',
    done: () => 'runtime 가 이번 turn 의 provider 결과 수락',
    exhausted: () => 'runtime 옵션 모두 소진 — 사용 가능한 path 없음',
  },
}

const STALLED_MEANING = '이 상태에서 너무 오래 멈춰 있습니다'
const STALLED_MEANING_DEV = 'state movement 이 이 창에서 정체된 것으로 보임'

export interface LaneReading {
  readonly value: string
  /** Seconds the current value has been observed without a transition. */
  readonly observedForSec: number
  readonly stalled: boolean
  readonly transitionCount: number
  readonly meaning: string
  readonly meaningDev: string
}

/** Current reading of one lane from the keeper's observation buffer, or null
 *  when nothing has been observed yet. Stall detection delegates to
 *  fsm-hub-lane-analysis.isObservedStall (the design's clStall thresholds,
 *  already the shipped SSOT). */
export function laneReading(
  observations: readonly CompositeObservation[],
  key: LaneKey,
  live: boolean,
  nowSec: number,
): LaneReading | null {
  const last = observations[observations.length - 1]
  if (!last) return null
  const value = last[key]
  const changedAt = laneChangedAt(observations as CompositeObservation[], key)
  const observedForSec = changedAt > 0 ? Math.max(0, nowSec - changedAt) : 0
  const stalled = isObservedStall(key, value, observedForSec)
  const fn = LANE_MEANING[key][value]
  const fnDev = LANE_MEANING_DEV[key][value]
  return {
    value,
    observedForSec,
    stalled,
    transitionCount: laneTransitionCount(observations as CompositeObservation[], key),
    meaning: stalled ? STALLED_MEANING : (fn ? fn(live) : '상태만 확인됨'),
    meaningDev: stalled ? STALLED_MEANING_DEV : (fnDev ? fnDev(live) : 'state 관측됨'),
  }
}

/* ── 스윔레인 세그먼트 ────────────────────────────────────────────────── */

export interface LaneQueueSegment {
  readonly value: string
  /** Position within the window, percent. */
  readonly leftPct: number
  readonly widthPct: number
  /** Full duration of the segment (also the part outside the window). */
  readonly durSec: number
  /** True when the segment started before the window's left edge. */
  readonly clipped: boolean
  readonly last: boolean
}

/** Clip run-length segments (from deriveSwimlaneSegments) into the
 *  [windowStart, windowEnd] observation window, design segments()-style. */
export function positionLaneSegments(
  segments: readonly SwimlaneSegment[],
  windowStart: number,
  windowEnd: number,
): LaneQueueSegment[] {
  const span = windowEnd - windowStart
  if (span <= 0) return []
  const out: LaneQueueSegment[] = []
  segments.forEach((seg, index) => {
    const from = Math.max(seg.from, windowStart)
    const to = Math.min(seg.to, windowEnd)
    if (to - from <= 0) return
    out.push({
      value: seg.value,
      leftPct: ((from - windowStart) / span) * 100,
      widthPct: ((to - from) / span) * 100,
      durSec: Math.max(0, seg.to - seg.from),
      clipped: seg.from < windowStart,
      last: index === segments.length - 1,
    })
  })
  return out
}

/** Design secTxt — compact duration for stall marks and read-outs. */
export function laneSecText(sec: number): string {
  const s = Math.max(0, Math.floor(sec))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  return `${(s / 3600).toFixed(1)}h`
}

/* ── 대기 인벤토리 (pl-* / wa-*) ──────────────────────────────────────── */

/** The stage a waiting source enters the keeper through (design STAGE order). */
export type LaneStage = 'external' | 'schedule' | 'queue' | 'operator' | 'keeper'

export const LANE_STAGES: readonly LaneStage[] = ['external', 'schedule', 'queue', 'operator', 'keeper']

export const LANE_STAGE_LABELS: Record<LaneStage, { label: string; wire: string }> = {
  external: { label: '외부 자극', wire: 'connector · attention store' },
  schedule: { label: '예약', wire: 'schedule_runner' },
  queue: { label: '큐', wire: 'keeper_event_queue' },
  operator: { label: '운영자', wire: 'hitl · console' },
  keeper: { label: 'keeper', wire: 'turn 실행' },
}

export type LaneSourceTone = 'volt' | 'warn' | 'ok' | 'dim' | 'bad'

interface LaneSourceDef {
  readonly label: string
  readonly tone: LaneSourceTone
  readonly stage: LaneStage
}

/** Design LANE_SOURCE, keyed by the raw wire token so a source the current
 *  closed union does not know yet (e.g. a future workspace_message) still
 *  lands in its design stage instead of disappearing. */
const LANE_SOURCE_DEFS: Record<string, LaneSourceDef> = {
  event_queue_pending: { label: '자율 이벤트', tone: 'volt', stage: 'queue' },
  workspace_message: { label: '다른 keeper 메시지', tone: 'volt', stage: 'queue' },
  chat_operation_queued: { label: '채팅 대기', tone: 'volt', stage: 'queue' },
  chat_operation_running: { label: '채팅 처리 중', tone: 'warn', stage: 'keeper' },
  hitl_pending: { label: '승인 대기', tone: 'warn', stage: 'operator' },
  external_attention: { label: '외부 알림', tone: 'volt', stage: 'external' },
  fusion_running: { label: 'Fusion 실행 중', tone: 'ok', stage: 'keeper' },
  schedule_waiting: { label: '예약 실행', tone: 'warn', stage: 'schedule' },
  owner_shutdown: { label: '종료 정리', tone: 'dim', stage: 'keeper' },
  operator_pending_confirm: { label: '운영자 확인', tone: 'warn', stage: 'operator' },
  read_error: { label: '읽기 오류', tone: 'bad', stage: 'queue' },
}

export function laneSourceLabel(source: string): string {
  return LANE_SOURCE_DEFS[source]?.label ?? enumLabel(source)
}

export function laneSourceTone(source: string): LaneSourceTone {
  return LANE_SOURCE_DEFS[source]?.tone ?? 'dim'
}

/** Design LANE_STATE — keeper-level lane state chip. */
export const LANE_STATE_PRESENT: Record<string, { label: string; tone: 'ok' | 'info' | 'warn' | 'dim' }> = {
  idle: { label: '비어 있음', tone: 'ok' },
  busy: { label: '처리 중', tone: 'info' },
  waiting: { label: '대기 중', tone: 'warn' },
  deferred: { label: '외부 응답 대기', tone: 'warn' },
}

export function laneStatePresent(state: string): { label: string; tone: 'ok' | 'info' | 'warn' | 'dim' } {
  return LANE_STATE_PRESENT[state] ?? { label: enumLabel(state), tone: 'dim' }
}

/** A count the server folded over a possibly-capped row list renders as a
 *  lower bound when the server itself says it truncated (design bounded()). */
export function boundedCount(value: number, truncated: boolean): string {
  return truncated ? `≥${value}` : `${value}`
}

export interface LaneStageItem {
  readonly source: string
  readonly label: string
  readonly count: string
  readonly tone: LaneSourceTone
}

/** Per-stage source counts for the pipeline strip, preserving the server's
 *  own per-source truncation verdicts. Unknown sources stay visible in
 *  `unknown` rather than being filed into a stage they were never assigned. */
export function laneStageBreakdown(entry: DashboardKeeperWaitingKeeper): {
  byStage: Record<LaneStage, LaneStageItem[]>
  unknown: LaneStageItem[]
} {
  const truncated = entry.truncated_sources ?? {}
  const byStage: Record<LaneStage, LaneStageItem[]> = {
    external: [], schedule: [], queue: [], operator: [], keeper: [],
  }
  const unknown: LaneStageItem[] = []
  Object.entries(entry.sources ?? {})
    .sort(([, a], [, b]) => b - a)
    .forEach(([source, count]) => {
      const def = LANE_SOURCE_DEFS[source]
      const item: LaneStageItem = {
        source,
        label: laneSourceLabel(source),
        count: boundedCount(count, truncated[source] === true),
        tone: laneSourceTone(source),
      }
      if (def) byStage[def.stage].push(item)
      else unknown.push(item)
    })
  return { byStage, unknown }
}

/** Epoch seconds the row has been waiting since, or null when the server
 *  recorded no timestamp (row renders with the design's 시각 미기록 arm). */
export function waitingRowSinceSec(row: DashboardKeeperWaitingRow): number | null {
  if (row.since != null && Number.isFinite(row.since)) return row.since
  if (row.since_iso == null) return null
  const parsed = Date.parse(row.since_iso)
  return Number.isFinite(parsed) ? parsed / 1000 : null
}

/** Oldest observation first (오래 기다린 순서). Equal/missing timestamps keep
 *  their server order, and missing timestamps stay visible at the end. */
export function waitingRowsOldestFirst(
  rows: readonly DashboardKeeperWaitingRow[],
): DashboardKeeperWaitingRow[] {
  return rows
    .map((row, serverIndex) => ({ row, serverIndex, since: waitingRowSinceSec(row) }))
    .sort((left, right) => {
      if (left.since == null && right.since == null) return left.serverIndex - right.serverIndex
      if (left.since == null) return 1
      if (right.since == null) return -1
      return left.since - right.since || left.serverIndex - right.serverIndex
    })
    .map(({ row }) => row)
}

export function waitingAgeMinutes(row: DashboardKeeperWaitingRow, nowSec: number): number | null {
  const since = waitingRowSinceSec(row)
  if (since == null) return null
  return Math.max(0, (nowSec - since) / SECONDS_PER_MINUTE)
}

/** Log position on the age axis: a 2-minute and a 3-day row both stay
 *  readable on one strip. `axisMax` is the axis end in minutes. */
export function waitAxisPosition(minutes: number, axisMax: number): number {
  return Math.min(100, (Math.log10(1 + minutes) / Math.log10(1 + axisMax)) * 100)
}

/** The age axis spans at least one day so the 지금/1시간/1일 ticks keep their
 *  design meaning even when every row is fresh. */
export function waitAxisMaxMinutes(ages: readonly (number | null)[]): number {
  let max = DAY_MINUTES
  for (const age of ages) {
    if (age != null && age > max) max = age
  }
  return max
}

/** Design agoTxt / untilTxt — minute-precision Korean age/deadline text. */
export function laneAgoText(minutes: number | null): string {
  if (minutes == null) return '시각 미기록'
  const m = Math.max(0, Math.floor(minutes))
  if (m < 60) return `${m}분 전`
  if (m < DAY_MINUTES) return `${Math.floor(m / HOUR_MINUTES)}시간 전`
  return `${Math.floor(m / DAY_MINUTES)}일 전`
}

export function laneUntilText(minutes: number): string {
  const m = Math.max(0, Math.floor(minutes))
  if (m < 60) return `${m}분 후`
  if (m < DAY_MINUTES) return `${Math.floor(m / HOUR_MINUTES)}시간 후`
  return `${Math.floor(m / DAY_MINUTES)}일 후`
}

/** Minutes until a due timestamp, or null when absent/unparseable. */
export function waitingDueMinutes(row: DashboardKeeperWaitingRow, nowSec: number): number | null {
  if (row.due_at != null && Number.isFinite(row.due_at)) {
    return Math.max(0, (row.due_at - nowSec) / SECONDS_PER_MINUTE)
  }
  if (row.due_at_iso == null) return null
  const parsed = Date.parse(row.due_at_iso)
  if (!Number.isFinite(parsed)) return null
  return Math.max(0, (parsed / 1000 - nowSec) / SECONDS_PER_MINUTE)
}

/* ── 예약 wake 드레인 (dl-* / dm-*) ───────────────────────────────────── */

/** Queue-evidence axis of the drain matrix (design Q_AXIS). */
export const DRAIN_QUEUE_AXIS = ['matched_pending', 'not_found', 'read_error', 'unrecognized_receipt'] as const

/** Reaction-evidence axis of the drain matrix (design R_AXIS; null = 행 없음). */
export const DRAIN_REACTION_AXIS: readonly (string | null)[] = [
  'matched_consumed_ack', 'matched_turn_started', 'matched_stimulus', 'not_found', 'quarantined', 'read_error', null,
]

/** keeper_reaction_evidence statuses that prove the keeper handled the
 *  stimulus. matched_stimulus is deliberately absent — it is the producer's
 *  own dispatch record (see queue-drain-status.ts header). */
const REACTED: ReadonlySet<string> = new Set(['matched_consumed_ack', 'matched_turn_started'])

/** Mirror of queue-drain-status.ts stateOf() on bare (queue, reaction)
 *  projection statuses, for matrix cells that have no request row behind
 *  them. Keep the decision table in lockstep — lane-queue-model.test.ts
 *  asserts parity against queueDrainStatusOf for every axis combination. */
export function drainStateOfEvidence(
  queue: string | null | undefined,
  reaction: string | null | undefined,
): QueueDrainState | null {
  if (queue == null) return null
  switch (queue) {
    case 'matched_pending':
      return 'pending'
    case 'read_error':
      return 'read_error'
    case 'unrecognized_receipt':
      return 'indeterminate'
    case 'not_found': {
      if (reaction != null && REACTED.has(reaction)) return 'drained'
      if (reaction === 'matched_stimulus' || reaction === 'not_found') return 'missed'
      if (reaction === 'read_error') return 'read_error'
      if (reaction === 'quarantined') return 'evidence_invalid'
      return 'indeterminate'
    }
    default:
      return 'indeterminate'
  }
}

export type DrainTone = 'info' | 'ok' | 'bad' | 'warn' | 'dim'

/** Design DRAIN_PRESENT — per-state chip label, data-tone, the operator
 *  sentence (op, default view) and the wiring explanation (why, dev view). */
export const DRAIN_PRESENT: Record<QueueDrainState, { label: string; tone: DrainTone; op: string; why: string }> = {
  pending: { label: '큐 대기', tone: 'info', op: '아직 실행되지 않고 차례를 기다리는 중', why: 'wake 가 keeper_event_queue pending 에 있음 — 드레인 대기 중' },
  drained: { label: '완료', tone: 'ok', op: 'keeper 가 받아서 실행했다', why: '큐에서 빠졌고 keeper 반응이 기록됨 (consumed_ack / turn_finished / turn_started)' },
  cancelled: { label: '취소됨', tone: 'warn', op: '큐가 취소해서 keeper 턴 없이 끝났다 — 대상 keeper 가 없으면 예약 정의를 지우거나 옮겨야 한다', why: '큐에서 accepted cancellation 으로 빠짐 (owner-absent drain 등) — keeper 반응 없이 종결' },
  missed: { label: '누락', tone: 'bad', op: '보냈지만 아무도 실행하지 않았다 — 다시 걸어야 한다', why: 'dispatch 기록만 남았고 keeper 반응이 없음 — 큐에서 빠졌으나 아무도 소비 안 함' },
  read_error: { label: '읽기 오류', tone: 'warn', op: '기록을 읽지 못해 실행됐는지 알 수 없다', why: '큐 스냅샷 또는 reaction ledger 읽기 실패 — 드레인 상태 확인 불가' },
  evidence_invalid: { label: '증거 격리', tone: 'warn', op: '기록이 손상돼 실행 여부를 단정할 수 없다', why: '해당 occurrence 의 reaction ledger 행이 격리되어 정확한 판정 불가' },
  indeterminate: { label: '확인 불가', tone: 'dim', op: '남은 기록만으로는 확인할 수 없다', why: '영수증 · stimulus_id · ledger completeness 부재로 큐-반응 상관 불가' },
}

/** One scheduled keeper wake with queue evidence, flattened for the drain
 *  list/matrix. `keeper` / `at` are null when the evidence carries none —
 *  the row still renders, with the raw schedule id as its identity. */
export interface DrainEvidenceRow {
  readonly scheduleId: string
  readonly keeper: string | null
  readonly payload: string
  readonly atIso: string | null
  readonly queue: string
  readonly reaction: string | null
  readonly state: QueueDrainState
}

/** Drain row for one scheduled-automation request, or null when the request
 *  has no keeper-wake queue evidence (board posts, or nothing dispatched
 *  yet — the design's drainState null arm). */
export function drainRowOfRequest(
  request: DashboardScheduledAutomationRequest,
): DrainEvidenceRow | null {
  const queue = request.keeper_queue_evidence?.projection_status
  if (queue == null) return null
  const reaction = request.keeper_reaction_evidence?.projection_status ?? null
  const state = drainStateOfEvidence(queue, reaction)
  if (state === null) return null
  const keeper =
    request.keeper_queue_evidence?.keeper_name
    ?? request.keeper_reaction_evidence?.keeper_name
    ?? request.payload_target
    ?? null
  const atIso =
    request.last_wake?.started_at_iso
    ?? (request.last_wake?.started_at != null ? new Date(request.last_wake.started_at * 1000).toISOString() : null)
    ?? request.due_at_iso
    ?? (request.due_at != null ? new Date(request.due_at * 1000).toISOString() : null)
    ?? null
  return {
    scheduleId: request.schedule_id,
    keeper,
    payload: request.payload_summary ?? request.schedule_id,
    atIso,
    queue,
    reaction,
    state,
  }
}

/** Operator sort — actionable verdicts first (design DrainList order). */
const DRAIN_SORT_ORDER: readonly QueueDrainState[] = [
  'missed', 'read_error', 'evidence_invalid', 'pending', 'indeterminate', 'drained',
]

export function sortedDrainRows(
  requests: readonly DashboardScheduledAutomationRequest[],
): DrainEvidenceRow[] {
  return requests
    .map(drainRowOfRequest)
    .filter((row): row is DrainEvidenceRow => row !== null)
    .sort((a, b) => DRAIN_SORT_ORDER.indexOf(a.state) - DRAIN_SORT_ORDER.indexOf(b.state))
}

/** Legend entries of the operator drain list (design DrainList footer). */
export const DRAIN_LEGEND_STATES: readonly QueueDrainState[] = ['missed', 'pending', 'read_error', 'drained']

/* ── 라이프사이클 이벤트 (lc-*) ───────────────────────────────────────── */

export type LaneLifecycleTone = 'ok' | 'warn' | 'bad' | 'info' | 'dim'

const LIFECYCLE_EVENT_LABELS: Record<string, string> = {
  started: '기동됨',
  reconciled: '재조정됨',
  restarted: '재시작됨',
  supervisor_cleaned: '종료 정리됨',
  dead_cleaned: '종료 정리됨',
  purged: '완전 삭제됨',
}

const LIFECYCLE_EVENT_TONES: Record<string, LaneLifecycleTone> = {
  started: 'ok',
  reconciled: 'ok',
  restarted: 'warn',
  supervisor_cleaned: 'bad',
  dead_cleaned: 'bad',
  purged: 'info',
}

export interface LaneLifecycleItem {
  readonly event: string
  readonly label: string
  readonly tone: LaneLifecycleTone
  readonly phase: string | null
  readonly detail: string
  readonly ageMinutes: number | null
}

export function laneLifecycleItemOf(
  event: KeeperLifecycleEvent,
  nowSec: number,
): LaneLifecycleItem {
  const key = event.event.trim().toLowerCase()
  return {
    event: event.event,
    label: LIFECYCLE_EVENT_LABELS[key] ?? event.event.replace(/_/g, ' '),
    tone: LIFECYCLE_EVENT_TONES[key] ?? 'info',
    phase: event.phase,
    detail: event.detail,
    ageMinutes: event.ts > 0 ? Math.max(0, (nowSec - event.ts) / SECONDS_PER_MINUTE) : null,
  }
}
