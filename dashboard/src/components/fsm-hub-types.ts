import type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
} from '../api/keeper'

export type CompositeObservation = {
  ts: number
  phase: string
  turn: string
  decision: string
  cascade: string
  compaction: string
}

export type TransitionEntry = {
  ts: number
  from: string
  to: string
  field: string
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

export type HubState = {
  keeperName: string | null
  snapshot: KeeperCompositeSnapshot | null
  loading: boolean
  error: string | null
  lastFetchAt: number
  observations: CompositeObservation[]
}

export type HubAction =
  | { type: 'fetch_started'; keeperName: string }
  | { type: 'fetch_succeeded'; keeperName: string; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { type: 'fetch_failed'; keeperName: string; error: string }

export const MAX_OBSERVATIONS = 30
export const MAX_TRANSITION_HISTORY = 20

export const initialHubState: HubState = {
  keeperName: null,
  snapshot: null,
  loading: false,
  error: null,
  lastFetchAt: 0,
  observations: [],
}

export const TRANSITION_FIELDS: Array<{ field: string; key: keyof Omit<CompositeObservation, 'ts'> }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'cascade' },
  { field: 'KMC', key: 'compaction' },
]

export const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: 'Phase ⇔ Turn',
  no_cascade_before_measurement: 'Cascade ordering',
  compaction_atomicity: 'Compaction atomic',
  event_priority_monotone: 'Event priority',
  recovery_two_store_sync: 'Two-store sync',
}

export const LANE_LABELS: Record<keyof Omit<CompositeObservation, 'ts'>, string> = {
  phase: 'Keeper 생명주기',
  turn: '턴 주기',
  decision: '의사결정',
  cascade: '캐스케이드',
  compaction: '컨텍스트 압축',
}

/** Korean display names for raw FSM state values.
    Replaces English internals in PipelineStep and Swimlane. */
export const STATE_DISPLAY_NAMES: Record<string, string> = {
  // KTC
  idle: '대기',
  prompting: '프롬프트 구성',
  executing: '실행 중',
  compacting: '압축 중',
  finalizing: '마무리',
  // KDP
  undecided: '대기',
  guard_ok: '가드 통과',
  gate_rejected: '게이트 거부',
  tool_policy_selected: '도구 정책 적용',
  // KCL
  selecting: '선택 중',
  trying: '시도 중',
  done: '완료',
  exhausted: '소진',
  // KMC
  accumulating: '수집 중',
  // KSM
  Running: '가동 중',
  Compacting: '압축 중',
  HandingOff: '인수인계',
  Failing: '오류 발생',
  Crashed: '비정상 종료',
  Offline: '오프라인',
  Paused: '일시 중지',
  Stopped: '정지',
  Draining: '종료 준비',
  Restarting: '재시작',
  Dead: '종료됨',
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
  laneKey: keyof Omit<CompositeObservation, 'ts'>
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
