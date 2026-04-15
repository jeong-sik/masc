import { html } from 'htm/preact'
import { useEffect, useMemo, useReducer, useRef, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  type KeeperCompositeSnapshot,
  type KeeperCompositeInvariants,
} from '../api/keeper'
import { keepers } from '../store'
import { compositeTick } from '../composite-signals'
import { EmptyState } from './common/empty-state'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'

export type CompositeObservation = {
  ts: number
  phase: string
  turn: string
  decision: string
  cascade: string
  compaction: string
}

type TransitionEntry = {
  ts: number
  from: string
  to: string
  field: string
}

type InsightTone = 'ok' | 'info' | 'warn' | 'error'

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

type HubState = {
  keeperName: string | null
  snapshot: KeeperCompositeSnapshot | null
  loading: boolean
  error: string | null
  lastFetchAt: number
  observations: CompositeObservation[]
}

type HubAction =
  | { type: 'fetch_started'; keeperName: string }
  | { type: 'fetch_succeeded'; keeperName: string; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { type: 'fetch_failed'; keeperName: string; error: string }

const MAX_OBSERVATIONS = 30
const MAX_TRANSITION_HISTORY = 20

const initialHubState: HubState = {
  keeperName: null,
  snapshot: null,
  loading: false,
  error: null,
  lastFetchAt: 0,
  observations: [],
}

const TRANSITION_FIELDS: Array<{ field: string; key: keyof Omit<CompositeObservation, 'ts'> }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'cascade' },
  { field: 'KMC', key: 'compaction' },
]

const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: 'Phase ⇔ Turn',
  no_cascade_before_measurement: 'Cascade ordering',
  compaction_atomicity: 'Compaction atomic',
  event_priority_monotone: 'Event priority',
  recovery_two_store_sync: 'Two-store sync',
}

const LANE_LABELS: Record<keyof Omit<CompositeObservation, 'ts'>, string> = {
  phase: 'Keeper 생명주기',
  turn: '턴 주기',
  decision: '의사결정',
  cascade: '캐스케이드',
  compaction: '컨텍스트 압축',
}

function observeSnapshot(
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
): TransitionEntry[] {
  const entries: TransitionEntry[] = []
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

function laneChangedAt(
  observations: CompositeObservation[],
  key: keyof Omit<CompositeObservation, 'ts'>,
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

export type StateEntries = {
  phase: number
  turn: number
  decision: number
  cascade: number
  compaction: number
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

export type TimeAxisTick = { ts: number; label: string }

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

/** Collapse consecutive observations of a single lane into run-length
    segments. The final segment is extended to `boundsEnd` so the lane
    visually reaches the right edge of the timeline instead of stopping
    at the last observation ts. */
export function deriveSwimlaneSegments(
  observations: CompositeObservation[],
  key: keyof Omit<CompositeObservation, 'ts'>,
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

export function laneTransitionCount(
  observations: CompositeObservation[],
  key: keyof Omit<CompositeObservation, 'ts'>,
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

function isObservedStall(
  key: keyof Omit<CompositeObservation, 'ts'>,
  value: string,
  observedForSec: number,
): boolean {
  if (key === 'phase') {
    if (value === 'Failing') return observedForSec >= 90
    if (value === 'Compacting') return observedForSec >= 90
    if (value === 'HandingOff' || value === 'Draining' || value === 'Restarting') return observedForSec >= 60
    return false
  }
  if (key === 'turn') {
    if (value === 'prompting' || value === 'executing') return observedForSec >= 45
    if (value === 'compacting') return observedForSec >= 60
    if (value === 'finalizing') return observedForSec >= 30
    return false
  }
  if (key === 'cascade') {
    if (value === 'selecting') return observedForSec >= 30
    if (value === 'trying') return observedForSec >= 45
    return false
  }
  if (key === 'compaction') {
    return value === 'compacting' && observedForSec >= 60
  }
  return false
}

function laneMeaning(
  key: keyof Omit<CompositeObservation, 'ts'>,
  snapshot: KeeperCompositeSnapshot,
  observedForSec: number,
): { tone: InsightTone; meaning: string } {
  const value = key === 'phase'
    ? snapshot.phase
    : key === 'turn'
      ? snapshot.turn_phase
      : key === 'decision'
        ? snapshot.decision.stage
        : key === 'cascade'
          ? snapshot.cascade.state
          : snapshot.compaction.stage

  const base: { tone: InsightTone; meaning: string } = (() => {
    switch (key) {
    case 'phase':
      switch (value) {
        case 'Running':
          return snapshot.is_live
            ? { tone: 'info', meaning: 'parent lifecycle is healthy while the live turn advances' }
            : { tone: 'ok', meaning: 'no live turn; waiting for the next observation cycle' }
        case 'Failing':
          return { tone: 'error', meaning: 'recovery owns the keeper lifecycle until reconcile clears' }
        case 'Compacting':
          return { tone: 'warn', meaning: 'post-turn compaction currently owns the lifecycle' }
        case 'HandingOff':
          return { tone: 'warn', meaning: 'handoff is draining this keeper toward stop' }
        case 'Draining':
          return { tone: 'warn', meaning: 'the keeper is draining in-flight work before stop' }
        case 'Restarting':
          return { tone: 'warn', meaning: 'boot path is re-entering Running after restart' }
        case 'Paused':
          return { tone: 'info', meaning: 'operator pause keeps the lifecycle intentionally frozen' }
        case 'Stopped':
        case 'Offline':
          return { tone: 'info', meaning: 'no lifecycle activity is currently expected' }
        case 'Crashed':
        case 'Dead':
          return { tone: 'error', meaning: 'the lifecycle is terminal until an external recovery path runs' }
        default:
          return { tone: 'info', meaning: 'lifecycle state observed' }
      }
    case 'turn':
      switch (value) {
        case 'idle':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'turn context exists but work has not advanced yet' : 'no in-flight turn is being observed' }
        case 'prompting':
          return { tone: 'info', meaning: 'prompt assembly is still preparing the turn inputs' }
        case 'executing':
          return { tone: 'info', meaning: 'the turn is inside model/tool execution work' }
        case 'compacting':
          return { tone: 'warn', meaning: 'turn finalization is blocked on compaction finishing' }
        case 'finalizing':
          return { tone: 'info', meaning: 'the turn is sealing results and preparing the next idle snapshot' }
        default:
          return { tone: 'info', meaning: 'turn-cycle state observed' }
      }
    case 'decision':
      switch (value) {
        case 'undecided':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'decision work has not committed yet' : 'idle snapshots intentionally clear decision state' }
        case 'guard_ok':
          return { tone: 'info', meaning: 'guardrails allowed the turn to continue' }
        case 'gate_rejected':
          return { tone: 'warn', meaning: 'guardrails blocked the turn before tool/model work' }
        case 'tool_policy_selected':
          return { tone: 'info', meaning: 'tool policy selection has committed and execution can advance' }
        default:
          return { tone: 'info', meaning: 'decision state observed' }
      }
    case 'cascade':
      switch (value) {
        case 'idle':
          return { tone: 'ok', meaning: 'no provider failover work is active' }
        case 'selecting':
          return { tone: 'info', meaning: 'provider routing is selecting the next execution path' }
        case 'trying':
          return { tone: 'info', meaning: 'provider execution is in flight' }
        case 'done':
          return { tone: 'ok', meaning: 'cascade accepted a provider result for this turn' }
        case 'exhausted':
          return { tone: 'error', meaning: 'all cascade options were consumed without a usable path' }
        default:
          return { tone: 'info', meaning: 'cascade state observed' }
      }
    case 'compaction':
      switch (value) {
        case 'accumulating':
          return { tone: 'ok', meaning: 'memory is collecting compaction candidates, not executing yet' }
        case 'compacting':
          return { tone: 'warn', meaning: 'memory compaction is actively rewriting context state' }
        case 'done':
          return { tone: 'ok', meaning: 'compaction finished for the observed turn' }
        default:
          return { tone: 'info', meaning: 'compaction state observed' }
      }
    }
  })()

  if (base.tone !== 'error' && isObservedStall(key, value, observedForSec)) {
    return { tone: 'warn', meaning: 'state movement looks stalled on this screen' }
  }
  return base
}

export function deriveObservedLaneSummaries(
  snapshot: KeeperCompositeSnapshot,
  observations: CompositeObservation[],
  now: number,
): ObservedLaneSummary[] {
  return TRANSITION_FIELDS.map(({ field, key }) => {
    const changedAt = laneChangedAt(observations, key)
    const observedForSec = changedAt > 0 ? Math.max(0, now - changedAt) : 0
    const transitionCount = laneTransitionCount(observations, key)
    const meaning = laneMeaning(key, snapshot, observedForSec)
    const value = key === 'phase'
      ? snapshot.phase
      : key === 'turn'
        ? snapshot.turn_phase
        : key === 'decision'
          ? snapshot.decision.stage
          : key === 'cascade'
            ? snapshot.cascade.state
            : snapshot.compaction.stage
    const stalled = isObservedStall(key, value, observedForSec)

    return {
      field,
      label: LANE_LABELS[key],
      value,
      tone: stalled && meaning.tone !== 'error' ? 'warn' : meaning.tone,
      stalled,
      meaning: meaning.meaning,
      observedForSec,
      transitionCount,
    }
  })
}

function brokenInvariantKey(
  invariants: KeeperCompositeInvariants,
): keyof KeeperCompositeInvariants | null {
  const first = (Object.entries(invariants) as Array<[keyof KeeperCompositeInvariants, boolean]>)
    .find(([, ok]) => !ok)
  return first?.[0] ?? null
}

function invariantDetail(
  snapshot: KeeperCompositeSnapshot,
  key: keyof KeeperCompositeInvariants,
  ok: boolean,
): string {
  switch (key) {
    case 'phase_turn_alignment':
      return ok
        ? 'KSM/KTC/KMC agree on who owns compaction right now.'
        : `KSM=${snapshot.phase}, KTC=${snapshot.turn_phase}, KMC=${snapshot.compaction.stage} do not line up.`
    case 'no_cascade_before_measurement':
      return ok
        ? 'Cascade work only advances after measurement is captured.'
        : `measurement.captured=${String(snapshot.measurement.captured)} while KCL=${snapshot.cascade.state}.`
    case 'compaction_atomicity':
      return ok
        ? 'Compaction does not run outside the parent Compacting phase.'
        : `KMC=${snapshot.compaction.stage} but KSM=${snapshot.phase}.`
    case 'event_priority_monotone':
      return ok
        ? 'This turn has not emitted competing measurement snapshots.'
        : 'More than one measurement event appears to own the same turn.'
    case 'recovery_two_store_sync':
      return ok
        ? 'Recovery data and FSM condition are synchronized.'
        : `recovery.data_record=${String(snapshot.recovery.data_record)}, recovery.fsm_condition=${String(snapshot.recovery.fsm_condition)}.`
  }
}

function nextExpectedStep(snapshot: KeeperCompositeSnapshot): string {
  if (!snapshot.is_live) {
    return snapshot.last_outcome
      ? 'The next live turn should repopulate KTC/KDP/KCL from idle placeholders.'
      : 'No turn has completed yet; the first live turn should populate the observer.'
  }
  if (snapshot.phase === 'Failing' && snapshot.cascade.state === 'exhausted') {
    return 'A healthy provider path or manual reconcile must clear Failing before Running can resume.'
  }
  if (snapshot.phase === 'Compacting' || snapshot.compaction.stage === 'compacting') {
    return 'KMC should reach done and then KSM should hand control back to Running.'
  }
  if (snapshot.phase === 'HandingOff') {
    return 'The current keeper should stop once handoff completion is observed.'
  }
  if (snapshot.phase === 'Draining') {
    return 'Draining should complete before the lifecycle settles into Stopped.'
  }
  if (snapshot.decision.stage === 'gate_rejected') {
    return 'The blocked turn should finalize back to idle without entering cascade/tool execution.'
  }
  if (snapshot.cascade.state === 'selecting' || snapshot.cascade.state === 'trying') {
    return 'KCL should settle into done or exhausted once provider routing returns.'
  }
  switch (snapshot.turn_phase) {
    case 'prompting':
      return 'KTC should advance into executing once prompt assembly is complete.'
    case 'executing':
      return 'Execution should either finalize the turn or drive cascade/compaction transitions.'
    case 'compacting':
      return 'Turn finalization is waiting on compaction to finish.'
    case 'finalizing':
      return 'The next stable state should be idle with last_outcome updated.'
    default:
      return 'The next meaningful edge should come from the next observed lifecycle event.'
  }
}

export function deriveOperationalInsight(
  snapshot: KeeperCompositeSnapshot,
  observations: CompositeObservation[],
  now: number,
): OperationalInsight {
  const brokenInvariant = brokenInvariantKey(snapshot.invariants)
  if (brokenInvariant) {
    return {
      tone: 'error',
      headline: `Spec drift on ${INVARIANT_LABELS[brokenInvariant]}`,
      detail: invariantDetail(snapshot, brokenInvariant, false),
      nextStep: 'Treat this as an observer-level contract breach before trusting downstream state transitions.',
      evidence: [
        `KSM ${snapshot.phase}`,
        `KTC ${snapshot.turn_phase}`,
        `KCL ${snapshot.cascade.state}`,
      ],
    }
  }

  const lanes = deriveObservedLaneSummaries(snapshot, observations, now)
  const stalledLane = lanes.find(lane => lane.stalled)
  if (snapshot.recovery.data_record !== snapshot.recovery.fsm_condition) {
    return {
      tone: 'error',
      headline: 'Recovery stores diverged',
      detail: 'The manual-reconcile data record and FSM condition disagree, which should be unreachable under RFC-0003.',
      nextStep: 'Reconcile the recovery stores before treating the lifecycle as healthy again.',
      evidence: [
        `data ${String(snapshot.recovery.data_record)}`,
        `fsm ${String(snapshot.recovery.fsm_condition)}`,
      ],
    }
  }
  if (snapshot.recovery.data_record && snapshot.recovery.fsm_condition) {
    return {
      tone: 'warn',
      headline: 'Manual reconcile is pending',
      detail: 'Both recovery stores agree the keeper is waiting for manual reconcile to clear.',
      nextStep: 'Resolve the reconcile path before expecting Failing to return to Running.',
      evidence: [
        `KSM ${snapshot.phase}`,
        'manual reconcile required',
      ],
    }
  }
  if (snapshot.phase === 'Failing' && snapshot.cascade.state === 'exhausted') {
    return {
      tone: 'error',
      headline: 'Failing after cascade exhaustion',
      detail: 'The keeper has entered recovery with no remaining cascade path, so the turn cannot self-heal through provider failover.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        `KCL ${snapshot.cascade.state}`,
        snapshot.measurement.captured ? 'measurement captured' : 'measurement missing',
      ],
    }
  }
  if (snapshot.decision.stage === 'gate_rejected') {
    return {
      tone: 'warn',
      headline: 'Guardrail blocked the turn',
      detail: 'Decision pipeline reached gate_rejected, so execution should unwind without entering provider work.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KDP ${snapshot.decision.stage}`,
        `KTC ${snapshot.turn_phase}`,
        snapshot.measurement.auto_rules?.guardrail_reason ?? 'no guardrail reason',
      ],
    }
  }
  if (stalledLane) {
    return {
      tone: 'warn',
      headline: `${stalledLane.field} is not moving`,
      detail: `${stalledLane.value} has been observed for ${fmtDuration(stalledLane.observedForSec)} on this screen without a new edge.`,
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `${stalledLane.field} ${stalledLane.value}`,
        `${stalledLane.transitionCount} observed changes`,
      ],
    }
  }
  if (snapshot.phase === 'Compacting' || snapshot.compaction.stage === 'compacting') {
    return {
      tone: 'info',
      headline: 'Compaction currently owns the turn',
      detail: 'The parent lifecycle and memory lane both indicate that post-turn compaction is the active coordination point.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        `KMC ${snapshot.compaction.stage}`,
      ],
    }
  }
  if (snapshot.phase === 'HandingOff' || snapshot.phase === 'Draining' || snapshot.phase === 'Restarting') {
    return {
      tone: 'warn',
      headline: `${snapshot.phase} is the active lifecycle edge`,
      detail: 'The keeper is transitioning between stable lifecycle states, so the parent FSM matters more than sub-turn activity right now.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        `live ${String(snapshot.is_live)}`,
      ],
    }
  }
  if (!snapshot.is_live) {
    const idleSince = snapshot.last_outcome
      ? fmtDuration(Math.max(0, now - snapshot.last_outcome.ended_at))
      : 'no completed turn yet'
    return {
      tone: 'ok',
      headline: 'Idle snapshot is consistent',
      detail: snapshot.last_outcome
        ? `Sub-FSMs have fallen back to idle placeholders; the last completed turn ended ${idleSince} ago.`
        : 'The observer is idle and has not captured a completed turn yet.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        snapshot.last_outcome ? `turn #${snapshot.last_outcome.turn_id}` : 'no last_outcome',
      ],
    }
  }
  if (snapshot.cascade.state === 'selecting' || snapshot.cascade.state === 'trying') {
    return {
      tone: 'info',
      headline: 'Provider work is the active frontier',
      detail: 'Cascade has taken ownership of the live turn, so the important next edge is provider completion or exhaustion.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KTC ${snapshot.turn_phase}`,
        `KCL ${snapshot.cascade.state}`,
      ],
    }
  }
  return {
    tone: 'info',
    headline: 'Live turn is progressing normally',
    detail: 'No invariant drift or recovery issue is visible; the sub-FSMs look aligned for the current live turn.',
    nextStep: nextExpectedStep(snapshot),
    evidence: [
      `KSM ${snapshot.phase}`,
      `KTC ${snapshot.turn_phase}`,
      `KDP ${snapshot.decision.stage}`,
    ],
  }
}

function invariantRows(
  snapshot: KeeperCompositeSnapshot,
): Array<{ key: keyof KeeperCompositeInvariants; label: string; ok: boolean; detail: string }> {
  return (Object.entries(snapshot.invariants) as Array<[keyof KeeperCompositeInvariants, boolean]>)
    .map(([key, ok]) => ({
      key,
      label: INVARIANT_LABELS[key],
      ok,
      detail: invariantDetail(snapshot, key, ok),
    }))
}

function reduceHubState(state: HubState, action: HubAction): HubState {
  const current =
    state.keeperName === action.keeperName
      ? state
      : {
          ...initialHubState,
          keeperName: action.keeperName,
        }

  switch (action.type) {
    case 'fetch_started':
      return {
        ...current,
        loading: true,
        error: null,
      }
    case 'fetch_succeeded': {
      const observation = observeSnapshot(action.snapshot, action.fetchedAt)
      return {
        keeperName: action.keeperName,
        snapshot: action.snapshot,
        loading: false,
        error: null,
        lastFetchAt: action.fetchedAt,
        observations: appendCompositeObservation(current.observations, observation),
      }
    }
    case 'fetch_failed':
      return {
        ...current,
        loading: false,
        error: action.error,
      }
  }
}

/**
 * FSM Hub — architecture audit surface for the composite keeper lifecycle.
 *
 * Layout redesign: Hero (KSM) + Pipeline strip (KTC→KDP→KCL→KMC) +
 * Health grid (measurement/invariants/recovery) + collapsible graph.
 *
 * Data source: `/api/v1/keepers/:name/composite` (RFC-0003 §7).
 */
export function FsmHub() {
  const [selected, setSelected] = useState<string | null>(null)
  const [hub, dispatch] = useReducer(reduceHubState, initialHubState)
  const [pollTick, setPollTick] = useState(0)
  const [now, setNow] = useState(() => Date.now() / 1000)
  const [graphOpen, setGraphOpen] = useState(false)
  const [hoveredSegment, setHoveredSegment] = useState<HoveredSegment | null>(null)
  const requestIdRef = useRef(0)

  const keeperList = keepers.value
  const keeperNames = useMemo(
    () => keeperList.map(k => k.name).sort(),
    [keeperList],
  )
  const activeSelected = useMemo(() => {
    if (selected && keeperNames.includes(selected)) return selected
    return keeperNames[0] ?? null
  }, [keeperNames, selected])

  useEffect(() => {
    const id = setInterval(() => setPollTick(t => t + 1), 30_000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now() / 1000), 1_000)
    return () => clearInterval(id)
  }, [])

  const tick = compositeTick.value
  const shouldRefetchForTick =
    activeSelected != null && tick.name === activeSelected ? tick.ts_unix : 0

  useEffect(() => {
    if (!activeSelected) return
    const requestId = requestIdRef.current + 1
    requestIdRef.current = requestId
    dispatch({ type: 'fetch_started', keeperName: activeSelected })
    void (async () => {
      try {
        const data = await fetchKeeperComposite(activeSelected)
        if (requestIdRef.current !== requestId) return
        dispatch({
          type: 'fetch_succeeded',
          keeperName: activeSelected,
          snapshot: data,
          fetchedAt: Date.now() / 1000,
        })
      } catch (err) {
        if (requestIdRef.current !== requestId) return
        dispatch({
          type: 'fetch_failed',
          keeperName: activeSelected,
          error: err instanceof Error ? err.message : 'composite fetch failed',
        })
      }
    })()
  }, [activeSelected, shouldRefetchForTick, pollTick])

  const view = useMemo(
    () =>
      hub.keeperName === activeSelected
        ? hub
        : {
            ...initialHubState,
            keeperName: activeSelected,
          },
    [activeSelected, hub],
  )
  const history = useMemo(
    () => deriveTransitionHistory(view.observations),
    [view.observations],
  )
  const phaseLog = useMemo(
    () => derivePhaseLog(view.observations),
    [view.observations],
  )
  const stateEntries = useMemo(
    () => deriveStateEntries(view.observations),
    [view.observations],
  )
  const { snapshot, loading, error, lastFetchAt } = view

  return html`
    <div class="flex flex-col gap-3">
      ${/* ── Zone 1: Status Bar ── */ ''}
      <${StatusBar}
        snapshot=${snapshot}
        now=${now}
        lastFetchAt=${lastFetchAt}
        keeperNames=${keeperNames}
        selected=${activeSelected}
        onSelect=${setSelected}
        loading=${loading}
        transitionCount=${history.length}
        observationCount=${view.observations.length}
      />

      ${activeSelected == null ? html`
        <${EmptyState} message=${keeperNames.length > 0
          ? `위 탭에서 키퍼를 선택하면 composite FSM 스냅샷을 표시합니다 (${keeperNames.length}개 사용 가능)`
          : '등록된 키퍼가 없습니다 — MASC에 키퍼를 기동하면 자동으로 표시됩니다'} />
      ` : loading && !snapshot ? html`
        <div class="flex items-center justify-center gap-2 py-10 text-[11px] text-[var(--text-dim)]">
          <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>
          composite 스냅샷 로딩중
        </div>
      ` : error ? html`
        <${EmptyState} message=${error} compact />
      ` : snapshot ? html`
        <${OperationalMeaningPanel}
          snapshot=${snapshot}
          observations=${view.observations}
          now=${now}
        />

        ${/* ── Zone 2: Hero — KSM Phase ── */ ''}
        <${HeroPhase} snapshot=${snapshot} phaseLog=${phaseLog} phaseSince=${stateEntries?.phase ?? null} now=${now} />

        ${/* ── Zone 2b: Transition History Trail (collapsible) ── */ ''}
        <${CollapsibleZone} id="transition-trail" title="전환 이력" defaultOpen=${true}>
          <${TransitionTrail} history=${history} now=${now} hoveredSegment=${hoveredSegment} />
        <//>

        ${/* ── Zone 3: Turn Pipeline Strip ── */ ''}
        <${TurnPipelineStrip} snapshot=${snapshot} stateEntries=${stateEntries} now=${now} />

        ${/* ── Zone 3b: Swimlane Timeline (collapsible) ── */ ''}
        <${CollapsibleZone} id="swimlane" title="상태 타임라인" defaultOpen=${true}>
          <${SwimlaneTimeline}
            observations=${view.observations}
            now=${now}
            hoveredSegment=${hoveredSegment}
            onHoverSegment=${setHoveredSegment}
          />
        <//>

        ${/* ── Zone 4: Health Grid (collapsible) ── */ ''}
        <${CollapsibleZone} id="health-grid" title="상태 격자" defaultOpen=${true}>
          <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
            <${MeasurementCard} snapshot=${snapshot} />
            <${InvariantsPanel} snapshot=${snapshot} />
            <${RecoveryStatePanel}
              dataRecord=${snapshot.recovery.data_record}
              fsmCondition=${snapshot.recovery.fsm_condition}
            />
          </div>
        <//>

        ${/* ── Zone 5: Collapsible Graph ── */ ''}
        <details class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)]"
          open=${graphOpen}
          onToggle=${(e: Event) => setGraphOpen((e.target as HTMLDetailsElement).open)}
        >
          <summary class="cursor-pointer select-none px-4 py-2.5 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] hover:text-[var(--text-body)]">
            Compound Graph — 5 sub-FSMs (Cytoscape)
          </summary>
          <div class="px-3 pb-3">
            <${CompositeGraphPanel} snapshot=${snapshot} />
          </div>
        </details>
      ` : null}
    </div>
  `
}

// ── Zone 1: Status Bar ──────────────────────────────────

function StatusBar({
  snapshot,
  now,
  lastFetchAt,
  keeperNames,
  selected,
  onSelect,
  loading,
  transitionCount,
  observationCount,
}: {
  snapshot: KeeperCompositeSnapshot | null
  now: number
  lastFetchAt: number
  keeperNames: string[]
  selected: string | null
  onSelect: (n: string) => void
  loading: boolean
  transitionCount: number
  observationCount: number
}) {
  const liveBadge = snapshot
    ? snapshot.is_live
      ? html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono text-emerald-400 border-emerald-500/40 bg-emerald-500/10 animate-pulse">● LIVE</span>`
      : html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono text-[var(--text-dim)] border-white/10">○ idle ${fmtDuration(Math.max(0, now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)))}</span>`
    : null

  const staleSec = lastFetchAt > 0 ? Math.max(0, now - lastFetchAt) : 0

  return html`
    <div class="sticky top-0 z-20 rounded-xl border border-[var(--white-8)] bg-[var(--panel-dark-60)] backdrop-blur-md px-4 py-2.5 shadow-[0_4px_12px_rgba(0,0,0,0.25)]">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">FSM Hub</span>
          ${liveBadge}
          ${loading ? html`<span class="inline-block h-2.5 w-2.5 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>` : null}
          ${staleSec > 60 ? html`<span class="text-[9px] font-mono text-amber-400">${fmtDuration(staleSec)} ago</span>` : null}
        </div>
        <div class="flex items-center gap-1.5 flex-wrap" role="tablist" aria-label="Keeper selection">
          ${keeperNames.map((name, i) => {
            const active = name === selected
            const cls = active
              ? 'bg-[var(--accent-10)] border-[var(--accent-30)] text-[var(--accent)]'
              : 'bg-[var(--white-3)] border-[var(--white-8)] text-[var(--text-dim)] hover:text-[var(--text-body)] hover:border-[var(--accent-30)]'
            return html`
              <button
                role="tab"
                aria-selected=${active}
                tabindex=${active ? 0 : -1}
                class=${`rounded-full border px-2.5 py-0.5 text-[10px] font-mono transition-colors cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] focus-visible:ring-offset-1 focus-visible:ring-offset-[var(--bg-0)] ${cls}`}
                onClick=${() => onSelect(name)}
                onKeyDown=${(e: KeyboardEvent) => {
                  let next = -1
                  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % keeperNames.length
                  else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (i - 1 + keeperNames.length) % keeperNames.length
                  else if (e.key === 'Home') next = 0
                  else if (e.key === 'End') next = keeperNames.length - 1
                  if (next >= 0) {
                    e.preventDefault()
                    const nextName = keeperNames[next]
                    if (nextName) {
                      onSelect(nextName);
                      (e.currentTarget as HTMLElement)?.parentElement?.querySelectorAll<HTMLElement>('[role=tab]')[next]?.focus()
                    }
                  }
                }}
              >
                ${name.replace(/^keeper-|-agent$/g, '')}
              </button>
            `
          })}
        </div>
      </div>
      ${snapshot ? html`
        <div class="mt-1.5 flex items-center gap-2 text-[9px] font-mono flex-wrap">
          ${/* KPI micro-metrics */ ''}
          <span class="px-1.5 py-0.5 rounded border border-[var(--white-8)] text-[var(--text-body)]">
            turn ${snapshot.last_outcome ? `#${snapshot.last_outcome.turn_id}` : '—'}
          </span>
          <span class=${`px-1.5 py-0.5 rounded border ${transitionCount > 0 ? 'border-[rgba(129,140,248,0.3)] text-[#818cf8]' : 'border-[var(--white-8)] text-[var(--text-dim)]'}`}>
            ${transitionCount} transitions
          </span>
          <span class="px-1.5 py-0.5 rounded border border-[var(--white-8)] text-[var(--text-dim)]">
            ${observationCount} obs
          </span>
          ${/* Meta IDs */ ''}
          <span class="text-[var(--text-dim)] opacity-60">corr ${snapshot.correlation_id?.slice(-8) ?? '?'}</span>
          <span class="text-[var(--text-dim)] opacity-60">run ${snapshot.run_id?.slice(-8) ?? '?'}</span>
        </div>
      ` : null}
    </div>
  `
}

// ── Zone 2: Hero Phase ──────────────────────────────────

const INSIGHT_BADGE_CLS: Record<InsightTone, string> = {
  ok: 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]',
  info: 'text-[var(--accent)] border-[var(--accent-30)] bg-[var(--accent-10)]',
  warn: 'text-[#f59e0b] border-[rgba(245,158,11,0.3)] bg-[rgba(245,158,11,0.08)]',
  error: 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]',
}

/** Panel-level accent — border + subtle tinted overlay — so that the
    overall tone of the current operator insight is visible from the
    peripheral visual field. Neutral tones (ok/info) keep the default
    muted panel frame; warn/error lift the full panel so urgent state
    does not require reading the small top-right badge. */
const INSIGHT_PANEL_CLS: Record<InsightTone, string> = {
  ok: 'border-[var(--white-8)] bg-[var(--white-2)]',
  info: 'border-[var(--white-8)] bg-[var(--white-2)]',
  warn: 'border-[rgba(245,158,11,0.45)] bg-[rgba(245,158,11,0.04)] shadow-[0_0_0_1px_rgba(245,158,11,0.15)_inset]',
  error: 'border-[rgba(239,68,68,0.55)] bg-[rgba(239,68,68,0.05)] shadow-[0_0_0_1px_rgba(239,68,68,0.2)_inset]',
}

function OperationalMeaningPanel({
  snapshot,
  observations,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  observations: CompositeObservation[]
  now: number
}) {
  const insight = deriveOperationalInsight(snapshot, observations, now)
  const lanes = deriveObservedLaneSummaries(snapshot, observations, now)
  const panelCls = INSIGHT_PANEL_CLS[insight.tone]
  const isAlarm = insight.tone === 'warn' || insight.tone === 'error'

  return html`
    <div
      class=${`rounded-xl border p-4 transition-colors duration-300 ${panelCls}`}
      role=${isAlarm ? 'alert' : undefined}
      aria-live=${isAlarm ? 'polite' : undefined}
    >
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="min-w-0">
          <div class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[var(--text-muted)]">Operator Meaning</div>
          <div class="mt-1 text-[18px] font-semibold text-[var(--text-strong)]">${insight.headline}</div>
          <div class="mt-1 text-[11px] text-[var(--text-dim)] leading-relaxed">${insight.detail}</div>
        </div>
        <span class=${`rounded-full border px-2.5 py-0.5 text-[10px] font-mono ${INSIGHT_BADGE_CLS[insight.tone]}`}>
          ${insight.tone}
        </span>
      </div>

      <div class="mt-2 text-[10px] text-[var(--text-body)]">
        <span class="font-semibold text-[var(--text-muted)]">Next:</span> ${insight.nextStep}
      </div>

      <div class="mt-2 flex flex-wrap gap-1.5">
        ${insight.evidence.map(item => html`
          <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[9px] font-mono text-[var(--text-dim)]">
            ${item}
          </span>
        `)}
      </div>

      <div class="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-5">
        ${lanes.map(lane => html`
          <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
            <div class="flex items-center justify-between gap-2">
              <span class="text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${lane.field}</span>
              <span class=${`rounded-full border px-1.5 py-0.5 text-[8px] font-mono ${INSIGHT_BADGE_CLS[lane.tone]}`}>
                ${fmtDuration(lane.observedForSec)}
              </span>
            </div>
            <div class="mt-1 font-mono text-[13px] font-semibold text-[var(--text-strong)]">${lane.value}</div>
            <div class="mt-0.5 text-[9px] text-[var(--text-dim)]">${lane.label}</div>
            <div class="mt-1.5 text-[9px] leading-relaxed text-[var(--text-body)]">${lane.meaning}</div>
            <div class="mt-1 text-[8px] font-mono text-[var(--text-dim)]">
              ${lane.transitionCount} observed edge${lane.transitionCount === 1 ? '' : 's'}
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}

const PHASE_DOT_COLOR: Record<string, string> = {
  Running: 'bg-emerald-400',
  Compacting: 'bg-amber-400',
  HandingOff: 'bg-violet-400',
  Failing: 'bg-red-400',
  Crashed: 'bg-red-500',
  Draining: 'bg-amber-300',
  Restarting: 'bg-blue-400',
  Offline: 'bg-zinc-600',
  Paused: 'bg-zinc-600',
  Stopped: 'bg-zinc-600',
  Dead: 'bg-zinc-800',
}

function PhaseSparkline({ log }: { log: string[] }) {
  if (log.length < 2) return null
  return html`
    <div class="flex items-center gap-[3px] mt-2" title="Phase history (oldest → newest)">
      <span class="text-[8px] text-[var(--text-dim)] mr-1">history</span>
      ${log.map((phase, i) => {
        const isLast = i === log.length - 1
        const dotColor = PHASE_DOT_COLOR[phase] ?? 'bg-[var(--accent)]'
        const size = isLast ? 'w-2.5 h-2.5 ring-1 ring-white/20' : 'w-1.5 h-1.5'
        return html`<span class=${`rounded-full ${dotColor} ${size} shrink-0`} title=${phase}></span>`
      })}
    </div>
  `
}

function HeroPhase({
  snapshot,
  phaseLog,
  phaseSince,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  phaseLog: string[]
  phaseSince: number | null
  now: number
}) {
  const prevRef = useRef(snapshot.phase)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== snapshot.phase) {
      prevRef.current = snapshot.phase
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 2000)
      return () => clearTimeout(id)
    }
    return undefined
  }, [snapshot.phase])

  const phaseColor: Record<string, string> = {
    Running: 'text-emerald-400',
    Compacting: 'text-amber-400',
    HandingOff: 'text-violet-400',
    Failing: 'text-red-400',
    Crashed: 'text-red-500',
    Offline: 'text-[var(--text-dim)]',
    Paused: 'text-[var(--text-dim)]',
    Stopped: 'text-[var(--text-dim)]',
  }
  const color = phaseColor[snapshot.phase] ?? 'text-[var(--accent)]'
  const heldFor = phaseSince != null ? fmtDuration(Math.max(0, now - phaseSince)) : null

  return html`
    <div class=${`rounded-xl border p-5 transition-all duration-700 ${flash ? 'border-[var(--accent)] bg-[rgba(71,184,255,0.06)] shadow-[0_0_16px_rgba(71,184,255,0.2)]' : 'border-[var(--white-8)] bg-[var(--white-2)]'}`}
      role="status" aria-live="polite" aria-label=${`Keeper 상태: ${displayState(snapshot.phase)}${heldFor ? `, ${heldFor}` : ''}`}
      title=${STATE_DESCRIPTIONS[snapshot.phase] ?? snapshot.phase}
    >
      <div class="flex items-baseline justify-between">
        <div>
          <div class="text-[10px] font-semibold tracking-[0.06em] text-[var(--text-muted)]" id="ksm-label">Keeper 생명주기 <span class="font-mono text-[8px] text-[var(--text-dim)]">KSM</span></div>
          <div class=${`mt-1 font-mono text-[32px] font-bold tracking-tight ${color}`} aria-labelledby="ksm-label">
            ${displayState(snapshot.phase)}
          </div>
          <div class="mt-0.5 text-[9px] font-mono text-[var(--text-dim)]">${snapshot.phase}</div>
          ${heldFor ? html`
            <div class="mt-1 text-[10px] font-mono text-[var(--text-dim)]" aria-hidden="true">
              유지 <span class="text-[var(--text-body)]">${heldFor}</span>
            </div>
          ` : null}
        </div>
        ${flash ? html`<span class="text-[10px] text-[var(--accent)] animate-pulse font-mono" aria-live="assertive">상태 변경</span>` : null}
      </div>
      <${PhaseSparkline} log=${phaseLog} />
    </div>
  `
}

// ── Zone 3: Turn Pipeline Strip ─────────────────────────

/** Human-readable descriptions for sub-FSM states.
    Shown as native title tooltips on hover. */
const STATE_DESCRIPTIONS: Record<string, string> = {
  // KTC (Turn Cycle)
  idle: 'Waiting for the next heartbeat cycle to start a turn',
  prompting: 'Building the LLM prompt with context and tools',
  executing: 'LLM is generating a response or calling tools',
  compacting: 'Compressing context to fit within the window',
  finalizing: 'Post-turn cleanup: checkpoint save, metrics emit',
  // KDP (Decision Pipeline)
  undecided: 'No decision made yet — waiting for the turn to start',
  guard_ok: 'All safety guards passed, proceeding to tool execution',
  gate_rejected: 'A safety gate blocked the action (cost, deny list, etc.)',
  tool_policy_selected: 'Tool policy has been applied, tools filtered',
  // KCL (Cascade)
  selecting: 'Choosing the best provider from the cascade list',
  trying: 'Attempting inference with the selected provider',
  done: 'Provider responded successfully',
  exhausted: 'All providers in the cascade failed',
  // KMC (Compaction)
  accumulating: 'Collecting messages; context not yet full',
  // KSM (Phase) — used in Hero
  Running: 'Keeper is actively running turns',
  Compacting: 'Compacting context to reclaim token budget',
  HandingOff: 'Transferring state to the next generation',
  Failing: 'Experiencing errors, will retry or recover',
  Crashed: 'Unrecoverable error — needs operator intervention',
  Offline: 'Not started or explicitly shut down',
  Paused: 'Temporarily paused by operator',
  Stopped: 'Gracefully stopped',
  Draining: 'Finishing current work before shutdown',
  Restarting: 'Shutting down and restarting',
  Dead: 'Permanently terminated',
}

/** Korean display names for raw FSM state values.
    Replaces English internals in PipelineStep and Swimlane. */
const STATE_DISPLAY_NAMES: Record<string, string> = {
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
function displayState(value: string): string {
  return STATE_DISPLAY_NAMES[value] ?? value
}

function PipelineStep({
  label,
  shortLabel,
  value,
  isLast,
  sinceTs,
  now,
}: {
  label: string
  shortLabel: string
  value: string
  isLast?: boolean
  sinceTs: number | null
  now: number
}) {
  const prevRef = useRef(value)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== value) {
      prevRef.current = value
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 1200)
      return () => clearTimeout(id)
    }
    return undefined
  }, [value])

  const isActive = value !== 'idle' && value !== 'undecided' && value !== 'accumulating'
  const borderCls = flash
    ? 'border-[var(--accent)] shadow-[0_0_8px_rgba(71,184,255,0.35)]'
    : isActive
      ? 'border-[rgba(129,140,248,0.5)] shadow-[0_0_6px_rgba(129,140,248,0.15)]'
      : 'border-[var(--white-8)]'
  const bgCls = isActive && !flash
    ? 'bg-[rgba(129,140,248,0.04)]'
    : 'bg-[var(--white-2)]'
  const activePulse = isActive && !flash ? 'animate-pulse' : ''

  // Connector: animated dashes when active, static when idle
  const connectorCls = isActive
    ? 'border-t border-dashed border-[rgba(129,140,248,0.5)] animate-[marching-ants_1s_linear_infinite]'
    : 'border-t border-[var(--white-10)]'

  const heldFor = sinceTs != null ? fmtDuration(Math.max(0, now - sinceTs)) : null
  const stalenessCls = (() => {
    if (!heldFor || sinceTs == null) return 'text-[var(--text-dim)]'
    const ageSec = now - sinceTs
    if (!isActive) return 'text-[var(--text-dim)]'
    if (ageSec > 60) return 'text-[#f59e0b]'
    if (ageSec > 20) return 'text-[#facc15]'
    return 'text-[#818cf8]'
  })()

  return html`
    <div class="flex items-center gap-0 flex-1 min-w-0" role="listitem" aria-label=${`${label}: ${displayState(value)}${heldFor ? `, ${heldFor}` : ''}`}
      title=${`${label} (${shortLabel}): ${value} → ${displayState(value)}${heldFor ? ` · ${heldFor}` : ''}\n${STATE_DESCRIPTIONS[value] ?? ''}`}
    >
      <div class=${`flex-1 rounded-lg border px-3 py-2 transition-all duration-500 ${borderCls} ${bgCls}`}>
        <div class="flex items-center justify-between gap-1.5">
          <div class="flex items-center gap-1.5 min-w-0">
            ${isActive ? html`<span class="h-1.5 w-1.5 rounded-full bg-[#818cf8] ${activePulse} shrink-0"></span>` : null}
            <span class="text-[9px] font-semibold tracking-[0.04em] text-[var(--text-muted)]">${label}</span>
          </div>
          ${heldFor ? html`
            <span class=${`text-[9px] font-mono tabular-nums ${stalenessCls}`} aria-hidden="true">${heldFor}</span>
          ` : null}
        </div>
        <div class=${`mt-0.5 font-mono text-[13px] font-semibold ${isActive ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'} ${flash ? 'animate-pulse' : ''}`}>
          ${displayState(value)}
        </div>
        <div class="text-[8px] font-mono text-[var(--text-dim)] mt-0.5">${shortLabel} · ${value}</div>
      </div>
      ${!isLast ? html`<div class=${`hidden md:block w-5 shrink-0 ${connectorCls}`}></div>` : null}
    </div>
  `
}

function TurnPipelineStrip({
  snapshot,
  stateEntries,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  stateEntries: StateEntries | null
  now: number
}) {
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        턴 파이프라인
      </div>
      <div class="flex flex-col gap-1 md:flex-row md:gap-0 md:items-stretch" role="list" aria-label="턴 파이프라인 단계">
        <${PipelineStep} shortLabel="KTC" label="턴 주기" value=${snapshot.turn_phase} sinceTs=${stateEntries?.turn ?? null} now=${now} />
        <${PipelineStep} shortLabel="KDP" label="의사결정" value=${snapshot.decision.stage} sinceTs=${stateEntries?.decision ?? null} now=${now} />
        <${PipelineStep} shortLabel="KCL" label="캐스케이드" value=${snapshot.cascade.state} sinceTs=${stateEntries?.cascade ?? null} now=${now} />
        <${PipelineStep} shortLabel="KMC" label="컨텍스트 압축" value=${snapshot.compaction.stage} sinceTs=${stateEntries?.compaction ?? null} now=${now} isLast />
      </div>
    </div>
  `
}

// ── Zone 4: Health Grid ─────────────────────────────────

/** Human-readable descriptions for MeasurementCard auto-rule flags.
    Indexed by rule name → { on: "this fires next turn", off: "nothing
    pending" } so the tooltip reflects the active half of the flag. */
const MEASUREMENT_FLAG_DESCRIPTIONS: Record<string, { on: string; off: string }> = {
  reflect: {
    on: 'Keeper will pause before the next turn to self-evaluate its recent output (Reflexion loop).',
    off: 'No reflection pending — keeper runs its next turn without self-check.',
  },
  plan: {
    on: 'Keeper will re-plan its remaining steps before executing the next action.',
    off: 'No re-plan scheduled — keeper follows its existing plan.',
  },
  compact: {
    on: 'Context compaction is scheduled — older messages will be summarized to reclaim token budget.',
    off: 'No compaction pending — the context window still has room.',
  },
  handoff: {
    on: 'Keeper will emit a handover capsule and pass state to the next generation.',
    off: 'No handoff scheduled — this generation continues running.',
  },
  guardrail: {
    on: 'A guardrail has tripped — the keeper will halt pending operator intervention.',
    off: 'No guardrail active — keeper runs under its normal safety envelope.',
  },
}

function MeasurementCard({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const m = snapshot.measurement
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Measurement
      </div>
      ${m.captured && m.auto_rules ? html`
        <div class="flex flex-col gap-1.5 text-[11px] text-[var(--text-body)]">
          <div class="flex flex-wrap gap-1.5 font-mono">
            <${Flag} label="reflect" on=${m.auto_rules.reflect} />
            <${Flag} label="plan" on=${m.auto_rules.plan} />
            <${Flag} label="compact" on=${m.auto_rules.compact} />
            <${Flag} label="handoff" on=${m.auto_rules.handoff} />
          </div>
          <div class="flex items-center gap-2 font-mono">
            <${Flag} label="guardrail" on=${m.auto_rules.guardrail_stop} tone="warn" />
            <span
              class="text-[10px] text-[var(--text-dim)] cursor-help"
              title="Goal drift: 0 = keeper is on-target; higher = keeper output is diverging from its declared goal. Values above ~0.5 typically trigger the guardrail."
            >drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-[9px] text-[#f59e0b] mt-0.5">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="text-[10px] text-[var(--text-dim)]">키퍼가 첫 턴을 완료하면 auto-rules가 여기 표시됩니다</div>
      `}
    </div>
  `
}

export function flagTooltip(label: string, on: boolean): string {
  const desc = MEASUREMENT_FLAG_DESCRIPTIONS[label]
  if (!desc) return `${label}: ${on ? 'active' : 'inactive'}`
  return `${label} (${on ? 'active' : 'inactive'})\n${on ? desc.on : desc.off}`
}

function Flag({ label, on, tone = 'ok' }: { label: string; on: boolean; tone?: 'ok' | 'warn' }) {
  const offCls = 'text-[var(--text-dim)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[#f59e0b] border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)]'
      : 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
  return html`
    <span
      class=${`rounded-full border px-2 py-0.5 text-[10px] cursor-help ${on ? onCls : offCls}`}
      title=${flagTooltip(label, on)}
    >
      ${label}
    </span>
  `
}

/** Plain-english safety-property descriptions per invariant key.
    Each entry names *what* the invariant guards and *what breaks* if
    it's violated, so an operator reading a red row in the panel
    understands the blast radius without cross-referencing the keeper
    RFC. Based on RFC-0003 composite keeper lifecycle contracts. */
const INVARIANT_DESCRIPTIONS: Record<string, string> = {
  phase_turn_alignment:
    'The KSM phase (Running / Compacting / HandingOff / …) must match what the KTC turn lane is doing. A drift means the two state machines disagree on which mode the keeper is in.',
  no_cascade_before_measurement:
    'Cascade selection must not begin before the measurement phase captures auto-rules. A violation usually means a provider call fired without the guardrail/drift checks that gate it.',
  compaction_atomicity:
    'Compaction must be atomic — a turn either sees the old context or the new one, never a half-compacted state. A break corrupts message ordering or duplicates content.',
  event_priority_monotone:
    'Event_bus priorities must be monotone (higher priority delivered first). A break means a critical event was delivered after a lower-priority one, which can skew keeper decisions.',
  recovery_two_store_sync:
    'Data-record and FSM-condition stores must agree on the same recovery point. A drift here means a restart would replay from an inconsistent checkpoint.',
}

export function invariantDescription(key: string): string {
  return INVARIANT_DESCRIPTIONS[key] ?? 'Invariant defined by the keeper composite contract.'
}

function InvariantsPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const entries = invariantRows(snapshot)
  const okCount = entries.filter(entry => entry.ok).length
  const total = entries.length
  const allOk = okCount === total
  const badgeText = allOk ? `${total}/${total}` : `${okCount}/${total}`
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Safety
        </div>
        <span
          class=${`rounded-full border px-2 py-0.5 text-[9px] font-mono tabular-nums ${
            allOk
              ? 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
              : 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
          }`}
          title=${allOk
            ? `All ${total} keeper composite invariants hold.`
            : `${total - okCount} of ${total} invariants are currently violated.`}
        >
          ${badgeText}
        </span>
      </div>
      <ul class="flex flex-col gap-1">
        ${entries.map(entry => {
          const desc = invariantDescription(entry.key)
          const tooltip = `${entry.label} — ${entry.ok ? 'holds' : 'BROKEN'}\n${desc}`
          return html`
            <li class="flex gap-2 text-[10px] cursor-help" title=${tooltip}>
              <span class=${`mt-[5px] h-1.5 w-1.5 rounded-full shrink-0 ${entry.ok ? 'bg-[#22c55e]' : 'bg-[#ef4444]'}`}></span>
              <div class="min-w-0">
                <div class=${entry.ok ? 'text-[var(--text-body)]' : 'text-[#f87171] font-semibold'}>
                  ${entry.label}
                </div>
                <div class="text-[8px] leading-relaxed text-[var(--text-dim)]">
                  ${entry.detail}
                </div>
              </div>
            </li>
          `
        })}
      </ul>
    </div>
  `
}

const RECOVERY_STATE_DESCRIPTIONS: Record<string, string> = {
  clean:
    'Both data-record and FSM-condition stores agree — no recovery action needed. A restart from this state will resume cleanly.',
  reconcile_pending:
    'Both stores recorded recovery state but have not yet reconciled. The keeper will align them on the next heartbeat cycle.',
  'drift: data↑ fsm↓':
    'The data-record store advanced past the FSM-condition store. A restart may replay turns that the FSM already completed, causing duplicate tool calls unless journal idempotency is active.',
  'drift: fsm↑ data↓':
    'The FSM-condition store advanced past the data-record. A restart may lose checkpoint data, forcing the keeper to re-derive state from scratch.',
}

export function recoveryStateDescription(state: string): string {
  return RECOVERY_STATE_DESCRIPTIONS[state] ?? 'Recovery state defined by the keeper two-store sync contract.'
}

function RecoveryStatePanel({
  dataRecord,
  fsmCondition,
}: {
  dataRecord: boolean
  fsmCondition: boolean
}) {
  const state =
    !dataRecord && !fsmCondition ? 'clean' :
    dataRecord && fsmCondition ? 'reconcile_pending' :
    dataRecord && !fsmCondition ? 'drift: data↑ fsm↓' :
    'drift: fsm↑ data↓'
  const isClean = state === 'clean'
  const isDrift = state.startsWith('drift')
  const toneCls = isClean ? 'text-[#22c55e]' : isDrift ? 'text-[#ef4444]' : 'text-[#f59e0b]'
  const panelCls = isClean
    ? 'border-[var(--white-8)] bg-[var(--white-2)]'
    : isDrift
      ? 'border-[rgba(239,68,68,0.55)] bg-[rgba(239,68,68,0.05)] shadow-[0_0_0_1px_rgba(239,68,68,0.2)_inset]'
      : 'border-[rgba(245,158,11,0.45)] bg-[rgba(245,158,11,0.04)] shadow-[0_0_0_1px_rgba(245,158,11,0.15)_inset]'

  return html`
    <div
      class=${`rounded-xl border p-3 transition-colors duration-300 ${panelCls}`}
      role=${isDrift ? 'alert' : undefined}
      aria-live=${isDrift ? 'polite' : undefined}
      title=${recoveryStateDescription(state)}
    >
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Recovery
      </div>
      <div class=${`font-mono text-[13px] font-semibold ${toneCls}`}>${state}</div>
      <div class="mt-1.5 flex gap-3 text-[9px] text-[var(--text-dim)]">
        <span class="cursor-help" title="data_record: true means the data store has recorded a recovery point that hasn't been reconciled yet.">
          data <span class="font-mono">${String(dataRecord)}</span>
        </span>
        <span class="cursor-help" title="fsm_condition: true means the FSM store has recorded a recovery condition that hasn't been reconciled yet.">
          fsm <span class="font-mono">${String(fsmCondition)}</span>
        </span>
      </div>
    </div>
  `
}

// ── Compound Graph (collapsed by default) ───────────────

function CompositeGraphPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(() => buildCompositeFsmSpec({
    phase: snapshot.phase,
    turnPhase: snapshot.turn_phase,
    decisionStage: snapshot.decision.stage,
    cascadeState: snapshot.cascade.state,
    compactionStage: snapshot.compaction.stage,
  }), [
    snapshot.phase,
    snapshot.turn_phase,
    snapshot.decision.stage,
    snapshot.cascade.state,
    snapshot.compaction.stage,
  ])

  return html`<${CytoscapeFsm} spec=${spec} height="320px" />`
}

// ── Zone 2b: Transition History Trail ────────────────────

const FIELD_COLOR: Record<string, string> = {
  KSM: 'text-[var(--accent)]',
  KTC: 'text-[#818cf8]',
  KDP: 'text-[#818cf8]',
  KCL: 'text-[#818cf8]',
  KMC: 'text-[#f59e0b]',
}

// ── Zone 3b: Swimlane Timeline ──────────────────────────

/** Run-length-encoded swimlane rendering. Each of the 5 sub-FSM lanes
    is a horizontal strip segmented proportionally by the time each
    value was held. Colors encode activity class rather than specific
    state name: idle-like states fade into the background, active
    states use indigo, and alarm-like states (crashed/failing/rejected/
    exhausted) turn red so operators can scan across lanes for
    correlated trouble at a glance. */
const SWIMLANE_LANES: Array<{
  key: keyof Omit<CompositeObservation, 'ts'>
  label: string
  short: string
}> = [
  { key: 'phase', label: 'Keeper 생명주기', short: 'KSM' },
  { key: 'turn', label: '턴 주기', short: 'KTC' },
  { key: 'decision', label: '의사결정', short: 'KDP' },
  { key: 'cascade', label: '캐스케이드', short: 'KCL' },
  { key: 'compaction', label: '컨텍스트 압축', short: 'KMC' },
]

const IDLE_LIKE_VALUES = new Set([
  'idle',
  'undecided',
  'accumulating',
  'Offline',
  'Paused',
  'Stopped',
])

const ALARM_VALUES = new Set([
  'Crashed',
  'Failing',
  'Dead',
  'gate_rejected',
  'exhausted',
])

function swimlaneSegmentColor(value: string): string {
  if (ALARM_VALUES.has(value)) return 'bg-[rgba(239,68,68,0.5)]'
  if (IDLE_LIKE_VALUES.has(value)) return 'bg-[rgba(255,255,255,0.04)]'
  if (value === 'Compacting' || value === 'compacting') return 'bg-[rgba(245,158,11,0.45)]'
  if (value === 'HandingOff') return 'bg-[rgba(167,139,250,0.5)]'
  return 'bg-[rgba(129,140,248,0.45)]'
}

/** Keyboard navigation across swimlane segments.
    ArrowLeft/Right: move within the same lane.
    ArrowUp/Down: move to the adjacent lane, preserving segment index
    (clamped to the target lane's segment count).
    Home/End: jump to the first/last segment of the current lane. */
function handleSwimlaneKey(
  ev: KeyboardEvent,
  laneIndex: number,
  segIndex: number,
): void {
  const target = ev.currentTarget
  if (!(target instanceof HTMLElement)) return
  const root = target.closest('[data-fsm-swimlane-root]')
  if (!root) return
  const findButton = (ln: number, sg: number): HTMLElement | null =>
    root.querySelector<HTMLElement>(
      `button[data-lane-index="${ln}"][data-seg-index="${sg}"]`,
    )
  const lastSeg = (ln: number): number => {
    const items = root.querySelectorAll<HTMLElement>(`button[data-lane-index="${ln}"]`)
    return items.length - 1
  }
  let nextLane = laneIndex
  let nextSeg = segIndex
  switch (ev.key) {
    case 'ArrowLeft':
      nextSeg = Math.max(0, segIndex - 1)
      break
    case 'ArrowRight':
      nextSeg = Math.min(lastSeg(laneIndex), segIndex + 1)
      break
    case 'ArrowUp':
      nextLane = Math.max(0, laneIndex - 1)
      nextSeg = Math.min(lastSeg(nextLane), segIndex)
      break
    case 'ArrowDown':
      nextLane = Math.min(SWIMLANE_LANES.length - 1, laneIndex + 1)
      nextSeg = Math.min(lastSeg(nextLane), segIndex)
      break
    case 'Home':
      nextSeg = 0
      break
    case 'End':
      nextSeg = lastSeg(laneIndex)
      break
    default:
      return
  }
  if (nextLane === laneIndex && nextSeg === segIndex) return
  ev.preventDefault()
  findButton(nextLane, nextSeg)?.focus()
}

function SwimlaneTimeline({
  observations,
  now,
  hoveredSegment,
  onHoverSegment,
}: {
  observations: CompositeObservation[]
  now: number
  hoveredSegment: HoveredSegment | null
  onHoverSegment: (seg: HoveredSegment | null) => void
}) {
  if (observations.length === 0) {
    return html`
      <div class="rounded-lg border border-dashed border-[var(--white-8)] px-4 py-2 text-center text-[10px] text-[var(--text-dim)]">
        30초 폴링 사이클에서 관측을 수집중 — 2회 이상 스냅샷이 쌓이면 5개 레인의 시간 흐름이 표시됩니다
      </div>
    `
  }
  const first = observations[0]
  if (!first) return null
  const spanStart = first.ts
  const spanEnd = Math.max(now, observations[observations.length - 1]?.ts ?? now)
  const spanWidth = Math.max(1, spanEnd - spanStart)
  const windowDuration = fmtDuration(Math.max(0, spanEnd - spanStart))
  const ticks = deriveTimeAxisTicks(spanStart, spanEnd)
  const showSeconds = spanWidth < 600
  const absFormatter = new Intl.DateTimeFormat(undefined, {
    hour: '2-digit',
    minute: '2-digit',
    ...(showSeconds ? { second: '2-digit' } : {}),
    hour12: false,
  })
  const fmtAbs = (ts: number) => absFormatter.format(new Date(ts * 1000))
  const laneDensity: Record<string, number> = {}
  let busiestLane = ''
  let busiestCount = 0
  for (const lane of SWIMLANE_LANES) {
    const count = laneTransitionCount(observations, lane.key)
    laneDensity[lane.short] = count
    if (count > busiestCount) {
      busiestLane = lane.short
      busiestCount = count
    }
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3" data-fsm-swimlane-root="true">
      <div class="mb-2 flex items-baseline justify-between gap-3 flex-wrap">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          상태 타임라인
        </div>
        <div class="flex items-center gap-1 flex-wrap">
          ${SWIMLANE_LANES.map(lane => {
            const count = laneDensity[lane.short] ?? 0
            const isBusiest = busiestLane === lane.short && count > 0
            return html`
              <span
                class=${`rounded-full border px-1.5 py-0.5 text-[9px] font-mono tabular-nums ${
                  count === 0
                    ? 'text-[var(--text-dim)] border-[var(--white-8)]'
                    : isBusiest
                      ? 'text-[#818cf8] border-[rgba(129,140,248,0.4)] bg-[rgba(129,140,248,0.08)]'
                      : 'text-[var(--text-body)] border-[var(--white-10)]'
                }`}
                title=${`${lane.label} · ${count} transition${count === 1 ? '' : 's'} in this window`}
              >${lane.short} ${count}</span>
            `
          })}
        </div>
        <div class="text-[9px] font-mono text-[var(--text-dim)]">
          <span>${fmtAbs(spanStart)}</span>
          <span class="mx-1 text-[var(--text-muted)]">→</span>
          <span>${fmtAbs(spanEnd)}</span>
          · window <span class="text-[var(--text-body)]">${windowDuration}</span>
          · <span class="text-[var(--text-body)]">${observations.length}</span> obs
        </div>
      </div>
      <div class="flex flex-col gap-1.5">
        ${SWIMLANE_LANES.map((lane, laneIndex) => {
          const segments = deriveSwimlaneSegments(observations, lane.key, spanEnd)
          return html`
            <div class="flex items-center gap-2">
              <div class="w-[44px] shrink-0 text-[9px] font-mono font-semibold text-[var(--text-muted)]">
                ${lane.short}
              </div>
              <div class="flex h-4 flex-1 overflow-hidden rounded border border-[var(--white-8)]" role="group" aria-label=${`${lane.label} swimlane with ${segments.length} segments`}>
                ${segments.map((seg, segIndex) => {
                  const pct = ((seg.to - seg.from) / spanWidth) * 100
                  const holdFor = fmtDuration(Math.max(0, seg.to - seg.from))
                  const isHovered =
                    hoveredSegment != null &&
                    hoveredSegment.laneKey === lane.key &&
                    hoveredSegment.from === seg.from &&
                    hoveredSegment.to === seg.to
                  const dimmed = hoveredSegment != null && !isHovered
                  const ariaLabel = `${lane.label}, ${displayState(seg.value)}, ${fmtAbs(seg.from)} ~ ${fmtAbs(seg.to)}, ${holdFor}`
                  return html`
                    <button
                      type="button"
                      data-fsm-swimlane="true"
                      data-lane-key=${lane.key}
                      data-lane-index=${laneIndex}
                      data-seg-index=${segIndex}
                      class=${`${swimlaneSegmentColor(seg.value)} h-full transition-all duration-200 border-r border-[rgba(0,0,0,0.25)] last:border-r-0 cursor-pointer focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] focus-visible:ring-inset ${isHovered ? 'ring-1 ring-[var(--accent)] brightness-125' : ''} ${dimmed ? 'opacity-40' : ''}`}
                      style=${`width: ${pct.toFixed(2)}%`}
                      title=${`${lane.label} (${lane.short}) · ${displayState(seg.value)} (${seg.value})\n${fmtAbs(seg.from)} → ${fmtAbs(seg.to)} · ${holdFor}`}
                      aria-label=${ariaLabel}
                      onmouseenter=${() => onHoverSegment({ field: lane.short, laneKey: lane.key, from: seg.from, to: seg.to, value: seg.value })}
                      onmouseleave=${() => onHoverSegment(null)}
                      onfocus=${() => onHoverSegment({ field: lane.short, laneKey: lane.key, from: seg.from, to: seg.to, value: seg.value })}
                      onblur=${() => onHoverSegment(null)}
                      onkeydown=${(ev: KeyboardEvent) => handleSwimlaneKey(ev, laneIndex, segIndex)}
                    ></button>
                  `
                })}
              </div>
            </div>
          `
        })}
      </div>
      ${ticks.length > 0 ? html`
        <div class="mt-1 flex items-center gap-2" aria-hidden="true">
          <div class="w-[44px] shrink-0"></div>
          <div class="relative flex-1 h-3">
            ${ticks.map(tick => {
              const leftPct = ((tick.ts - spanStart) / spanWidth) * 100
              return html`
                <div
                  class="absolute top-0 flex flex-col items-center text-[var(--text-dim)]"
                  style=${`left: ${leftPct.toFixed(2)}%; transform: translateX(-50%)`}
                >
                  <div class="h-1 w-px bg-[var(--white-10)]"></div>
                  <div class="text-[8px] font-mono leading-none mt-0.5">${tick.label}</div>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}
      <div class="mt-2 flex flex-wrap items-center gap-2 text-[9px] text-[var(--text-dim)]">
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[rgba(129,140,248,0.45)]"></span>active</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[rgba(245,158,11,0.45)]"></span>compact</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[rgba(167,139,250,0.5)]"></span>handoff</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[rgba(239,68,68,0.5)]"></span>alarm</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm border border-[var(--white-8)] bg-[rgba(255,255,255,0.04)]"></span>idle</span>
      </div>
    </div>
  `
}

export function isTransitionInSegment(
  entry: { ts: number; field: string },
  segment: HoveredSegment | null,
): boolean {
  if (!segment) return false
  if (entry.field !== segment.field) return false
  return entry.ts >= segment.from && entry.ts <= segment.to
}

function TransitionTrail({
  history,
  now,
  hoveredSegment,
}: {
  history: { ts: number; from: string; to: string; field: string }[]
  now: number
  hoveredSegment: HoveredSegment | null
}) {
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const firstMatchIndex = useMemo(() => {
    if (!hoveredSegment) return -1
    return history.findIndex(entry => isTransitionInSegment(entry, hoveredSegment))
  }, [history, hoveredSegment])

  useEffect(() => {
    if (firstMatchIndex < 0) return
    const container = scrollRef.current
    if (!container) return
    const target = container.querySelector<HTMLElement>(`[data-trail-index="${firstMatchIndex}"]`)
    if (!target) return
    target.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }, [firstMatchIndex])

  if (history.length === 0) {
    return html`
      <div class="rounded-lg border border-dashed border-[var(--white-8)] px-4 py-2 text-center text-[10px] text-[var(--text-dim)]">
        아직 상태 전이가 관측되지 않았습니다 — 키퍼가 턴을 시작하거나 phase가 변경되면 자동으로 기록됩니다
      </div>
    `
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Transition History (${history.length})
      </div>
      <div ref=${scrollRef} class="flex flex-col gap-0.5 max-h-[120px] overflow-y-auto">
        ${history.map((entry, trailIndex) => {
          const ago = fmtDuration(Math.max(0, now - entry.ts))
          const color = FIELD_COLOR[entry.field] ?? 'text-[var(--text-body)]'
          const inSegment = isTransitionInSegment(entry, hoveredSegment)
          const dimmed = hoveredSegment != null && !inSegment
          const rowCls = inSegment
            ? 'bg-[rgba(71,184,255,0.1)] ring-1 ring-[rgba(71,184,255,0.3)] rounded px-1'
            : ''
          return html`
            <div
              data-trail-index=${trailIndex}
              class=${`flex items-center gap-2 text-[10px] font-mono leading-tight transition-opacity duration-150 ${dimmed ? 'opacity-40' : ''} ${rowCls}`}
            >
              <span class="w-[52px] shrink-0 text-right text-[var(--text-dim)]">${ago} ago</span>
              <span class=${`w-[28px] shrink-0 font-semibold ${color}`}>${entry.field}</span>
              <span class="text-[var(--text-dim)]">${entry.from}</span>
              <span class="text-[var(--text-muted)]">→</span>
              <span class="text-[var(--text-strong)]">${entry.to}</span>
            </div>
          `
        })}
      </div>
    </div>
  `
}

// ── Collapsible Zone ────────────────────────────────────

const COLLAPSED_ZONES_KEY = 'fsm-hub:collapsed-zones'

function loadCollapsedZones(): Set<string> {
  try {
    const stored = localStorage.getItem(COLLAPSED_ZONES_KEY)
    if (stored) return new Set(JSON.parse(stored) as string[])
  } catch { /* ignore corrupt localStorage */ }
  return new Set<string>()
}

function saveCollapsedZones(collapsed: Set<string>): void {
  try {
    localStorage.setItem(COLLAPSED_ZONES_KEY, JSON.stringify([...collapsed]))
  } catch { /* quota exceeded — non-critical */ }
}

function CollapsibleZone({
  id,
  title: zoneTitle,
  defaultOpen = true,
  children,
}: {
  id: string
  title: string
  defaultOpen?: boolean
  children: unknown
}) {
  const [collapsed, setCollapsed] = useState(() => {
    const stored = loadCollapsedZones()
    return stored.has(id) ? true : !defaultOpen
  })

  const toggle = () => {
    setCollapsed(prev => {
      const next = !prev
      const stored = loadCollapsedZones()
      if (next) stored.add(id)
      else stored.delete(id)
      saveCollapsedZones(stored)
      return next
    })
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] overflow-hidden">
      <button
        type="button"
        class="w-full flex items-center justify-between px-4 py-2 text-left hover:bg-[var(--white-3)] transition-colors cursor-pointer select-none"
        onClick=${toggle}
        aria-expanded=${!collapsed}
        aria-controls=${`zone-${id}`}
      >
        <span class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${zoneTitle}</span>
        <span class=${`text-[10px] text-[var(--text-dim)] transition-transform duration-200 ${collapsed ? '' : 'rotate-180'}`}>▾</span>
      </button>
      ${!collapsed ? html`<div id=${`zone-${id}`} class="px-4 pb-3">${children}</div>` : null}
    </div>
  `
}

// ── Utilities ───────────────────────────────────────────

function fmtDuration(seconds: number): string {
  if (seconds < 0) return '0s'
  const s = Math.floor(seconds)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  const rem = s % 60
  if (m < 60) return `${m}m ${rem}s`
  const h = Math.floor(m / 60)
  return `${h}h ${m % 60}m`
}
