import type { KeeperCompositeSnapshot } from '../api/keeper'
import { isCrashedPhase } from '../lib/keeper-predicates'
import { unixSecondsToDate } from '../lib/format-time'

import {
  type CompositeObservation,
  type DwellEntry,
  type LaneDwell,
  type LaneKey,
  type StateEntries,
  type SwimlaneSegment,
  type TimeAxisTick,
  type TopTransition,
  MAX_OBSERVATIONS,
  MAX_TRANSITION_HISTORY,
  TRANSITION_FIELDS,
} from './fsm-hub-types'

export function observeSnapshot(
  snapshot: KeeperCompositeSnapshot,
  ts: number,
): CompositeObservation {
  return {
    ts,
    phase: snapshot.phase,
    turn: snapshot.turn_phase,
    decision: snapshot.decision.stage,
    runtime: snapshot.runtime.state,
    compaction: snapshot.compaction.stage,
  }
}

function sameObservation(
  left: CompositeObservation,
  right: CompositeObservation,
): boolean {
  return left.phase === right.phase
    && left.turn === right.turn
    && left.decision === right.decision
    && left.runtime === right.runtime
    && left.compaction === right.compaction
}

export function appendCompositeObservation(
  observations: CompositeObservation[],
  next: CompositeObservation,
  maxEntries = MAX_OBSERVATIONS,
): CompositeObservation[] {
  const last = observations[observations.length - 1]
  if (last && sameObservation(last, next)) return observations
  return [...observations, next].slice(-Math.max(1, maxEntries))
}

export function deriveTransitionHistory(
  observations: CompositeObservation[],
  maxEntries = MAX_TRANSITION_HISTORY,
): Array<{ ts: number; from: string; to: string; field: string }> {
  const entries: Array<{ ts: number; from: string; to: string; field: string }> = []
  for (let index = 1; index < observations.length; index += 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    for (const { field, key } of TRANSITION_FIELDS) {
      if (prev[key] !== next[key]) {
        entries.push({
          ts: next.ts,
          from: prev[key],
          to: next[key],
          field,
        })
      }
    }
  }
  return entries.slice(-Math.max(1, maxEntries)).reverse()
}

/** Aggregate the most frequent (from → to) transitions per lane across the
    full observation buffer. Unlike [deriveTransitionHistory], which slices
    to the last N events for the recency log, this counts every adjacent
    (prev, next) pair in [observations] so the ranking reflects the full
    window. Ties broken by lane order (TRANSITION_FIELDS), then alphabetical. */
export function deriveTopTransitions(
  observations: CompositeObservation[],
  limit = 5,
): TopTransition[] {
  const counts = new Map<string, TopTransition>()
  for (let index = 1; index < observations.length; index += 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    for (const { field, key } of TRANSITION_FIELDS) {
      if (prev[key] === next[key]) continue
      const cacheKey = `${field}|${prev[key]}|${next[key]}`
      const existing = counts.get(cacheKey)
      if (existing) {
        existing.count += 1
      } else {
        counts.set(cacheKey, {
          field,
          from: prev[key],
          to: next[key],
          count: 1,
        })
      }
    }
  }
  const fieldOrder = new Map(
    TRANSITION_FIELDS.map(({ field }, idx) => [field, idx]),
  )
  return Array.from(counts.values())
    .sort((a, b) => {
      if (b.count !== a.count) return b.count - a.count
      const fa = fieldOrder.get(a.field) ?? 99
      const fb = fieldOrder.get(b.field) ?? 99
      if (fa !== fb) return fa - fb
      const fromCmp = a.from.localeCompare(b.from)
      if (fromCmp !== 0) return fromCmp
      return a.to.localeCompare(b.to)
    })
    .slice(0, Math.max(0, limit))
}

/** Plain-Korean inference of *why* a transition fired, attributable from
    the transition shape alone (Watson-style retroactive reasoning,
    arxiv 2411.03455 — applied to FSM transitions instead of LLM tool
    calls). Returns null when the transition has no obvious cause we
    can attribute without additional event-bus signals. */
export function inferTransitionReason(field: string, from: string, to: string): string | null {
  if (field === 'KTC') {
    if (from === 'idle' && to === 'executing') return '턴이 시작되었습니다 — runtime 호출 진행'
    if (from === 'executing' && to === 'idle') return '턴이 정상 종료되어 대기 상태로 복귀'
    if (to === 'compacting') return 'KMC 가 compaction 단계를 시작 — 컨텍스트 압축 중'
    if (to === 'finalizing') return '턴 마무리 — checkpoint/메트릭 emit'
    if (from === 'idle' && to === 'prompting') return '프롬프트 구성 시작'
  }
  if (field === 'KSM') {
    if (to === 'Compacting') return 'KSM 이 lifecycle 차원에서 compaction 진입'
    if (to === 'HandingOff') return '키퍼 인계 시작 — 다른 keeper 로 전환 준비'
    if (to === 'Failing') return '연속 실패 임계 도달 — 다음 fail 시 Crashed 가능'
    if (isCrashedPhase(to)) return '비정상 종료 — restart 정책 확인'
  }
  if (field === 'KDP') {
    if (from === 'undecided' && to === 'guard_ok') return '안전 가드 모두 통과 — 도구 실행 단계로 진행'
    if (to === 'tool_policy_selected') return '호출 가능한 도구 목록이 정해짐'
  }
  if (field === 'KCL') {
    if (to === 'trying') return 'runtime 호출 진행 중'
    if (to === 'exhausted') return '모든 runtime lane 실패 — failover 소진'
    if (from === 'trying' && to === 'idle') return 'runtime 호출 종료 (성공/실패와 무관)'
  }
  if (field === 'KMC') {
    if (to === 'compacting') return '컨텍스트 압축 작업 시작 (KMC 동기화)'
    if (from === 'compacting' && to === 'accumulating') return '압축 완료 — 다시 누적 모드로'
  }
  return null
}

export function derivePhaseLog(
  observations: CompositeObservation[],
  maxEntries = MAX_OBSERVATIONS,
): string[] {
  const phases: string[] = []
  for (const observation of observations) {
    if (phases[phases.length - 1] !== observation.phase) {
      phases.push(observation.phase)
    }
  }
  return phases.slice(-Math.max(1, maxEntries))
}

export function laneChangedAt(
  observations: CompositeObservation[],
  key: LaneKey,
): number {
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

export function laneTransitionCount(
  observations: CompositeObservation[],
  key: LaneKey,
): number {
  let count = 0
  for (let index = 1; index < observations.length; index += 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    if (prev[key] !== next[key]) count += 1
  }
  return count
}

/** Single-pass scan returning the timestamp at which each lane last
    transitioned into its current value. Falls back to the earliest
    observation ts if the lane never changed (i.e. has been held since
    observation began). */
export function deriveStateEntries(
  observations: CompositeObservation[],
): StateEntries | null {
  const last = observations[observations.length - 1]
  const first = observations[0]
  if (!last || !first) return null
  const result: StateEntries = {
    phase: first.ts,
    turn: first.ts,
    decision: first.ts,
    runtime: first.ts,
    compaction: first.ts,
  }
  const seen: Record<keyof StateEntries, boolean> = {
    phase: false,
    turn: false,
    decision: false,
    runtime: false,
    compaction: false,
  }
  for (let index = observations.length - 1; index > 0; index -= 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    for (const key of ['phase', 'turn', 'decision', 'runtime', 'compaction'] as const) {
      if (!seen[key] && prev[key] !== next[key]) {
        result[key] = next.ts
        seen[key] = true
      }
    }
    if (seen.phase && seen.turn && seen.decision && seen.runtime && seen.compaction) break
  }
  return result
}

const TIME_AXIS_STEPS_SEC = [1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200]

/** Compute up to `maxTicks` evenly-spaced absolute-time tick marks that
    lie strictly inside `[spanStart, spanEnd]`. The step is rounded-[var(--r-1)] up
    to the nearest human-friendly value (1s..2h) so labels align on
    round clock moments, not arbitrary offsets. Returns empty when the
    span is too narrow to fit more than a single tick. */
export function deriveTimeAxisTicks(
  spanStart: number,
  spanEnd: number,
  maxTicks = 6,
): TimeAxisTick[] {
  const span = spanEnd - spanStart
  if (span <= 0 || maxTicks < 2) return []
  const desiredStep = span / Math.max(1, maxTicks - 1)
  const step =
    TIME_AXIS_STEPS_SEC.find(s => s >= desiredStep) ??
    TIME_AXIS_STEPS_SEC[TIME_AXIS_STEPS_SEC.length - 1] ??
    desiredStep
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

/** Collapse consecutive observations of a single lane into run-length
    segments. The final segment is extended to `boundsEnd` so the lane
    visually reaches the right edge of the timeline instead of stopping
    at the last observation ts. */
export function deriveSwimlaneSegments(
  observations: CompositeObservation[],
  key: LaneKey,
  boundsEnd: number,
): SwimlaneSegment[] {
  if (observations.length === 0) return []
  const segments: SwimlaneSegment[] = []
  for (let index = 0; index < observations.length; index += 1) {
    const current = observations[index]
    if (!current) continue
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

/** Per-lane dwell histogram. For each sub-FSM lane, sums the time spent in
    every observed state value across the in-memory observation buffer.
    [boundsEnd] (typically `Date.now() / 1000`) extends the trailing
    segment so the *current* state's dwell reflects "how long has it been
    held" instead of "interval between last two observations".

    Output: lanes in [TRANSITION_FIELDS] order, entries sorted by dwell
    desc. Empty observation buffer → empty array. */
export function deriveLaneDwellHistograms(
  observations: CompositeObservation[],
  boundsEnd: number,
): LaneDwell[] {
  if (observations.length === 0) return []
  const result: LaneDwell[] = []
  for (const { field, key } of TRANSITION_FIELDS) {
    const segments = deriveSwimlaneSegments(observations, key, boundsEnd)
    const dwellByValue = new Map<string, number>()
    let total = 0
    for (const seg of segments) {
      const seconds = Math.max(0, seg.to - seg.from)
      if (seconds === 0) continue
      dwellByValue.set(seg.value, (dwellByValue.get(seg.value) ?? 0) + seconds)
      total += seconds
    }
    const entries: DwellEntry[] = Array.from(dwellByValue.entries())
      .map(([value, seconds]) => ({
        value,
        seconds,
        pct: total > 0 ? (seconds / total) * 100 : 0,
      }))
      .sort((a, b) => {
        if (b.seconds !== a.seconds) return b.seconds - a.seconds
        return a.value.localeCompare(b.value)
      })
    if (entries.length === 0) continue
    result.push({
      field,
      laneKey: key,
      totalSeconds: total,
      entries,
    })
  }
  return result
}
