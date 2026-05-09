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
