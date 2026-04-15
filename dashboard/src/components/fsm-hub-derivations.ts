import type { KeeperCompositeSnapshot } from '../api/keeper'

import {
  type CompositeObservation,
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
    cascade: snapshot.cascade.state,
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
    && left.cascade === right.cascade
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
    cascade: first.ts,
    compaction: first.ts,
  }
  const seen: Record<keyof StateEntries, boolean> = {
    phase: false,
    turn: false,
    decision: false,
    cascade: false,
    compaction: false,
  }
  for (let index = observations.length - 1; index > 0; index -= 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    for (const key of ['phase', 'turn', 'decision', 'cascade', 'compaction'] as const) {
      if (!seen[key] && prev[key] !== next[key]) {
        result[key] = next.ts
        seen[key] = true
      }
    }
    if (seen.phase && seen.turn && seen.decision && seen.cascade && seen.compaction) break
  }
  return result
}

const TIME_AXIS_STEPS_SEC = [1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200]

/** Compute up to `maxTicks` evenly-spaced absolute-time tick marks that
    lie strictly inside `[spanStart, spanEnd]`. The step is rounded up
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
    ticks.push({ ts, label: formatter.format(new Date(ts * 1000)) })
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
