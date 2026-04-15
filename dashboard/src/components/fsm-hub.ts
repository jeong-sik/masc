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
  phase: 'keeper lifecycle',
  turn: 'turn cycle',
  decision: 'decision',
  cascade: 'cascade',
  compaction: 'compaction',
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

function laneTransitionCount(
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
        <${EmptyState} message="관찰할 키퍼를 선택하세요" />
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
        <${HeroPhase} snapshot=${snapshot} phaseLog=${phaseLog} />

        ${/* ── Zone 2b: Transition History Trail ── */ ''}
        <${TransitionTrail} history=${history} now=${now} />

        ${/* ── Zone 3: Turn Pipeline Strip ── */ ''}
        <${TurnPipelineStrip} snapshot=${snapshot} />

        ${/* ── Zone 4: Health Grid ── */ ''}
        <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
          <${MeasurementCard} snapshot=${snapshot} />
          <${InvariantsPanel} snapshot=${snapshot} />
          <${RecoveryStatePanel}
            dataRecord=${snapshot.recovery.data_record}
            fsmCondition=${snapshot.recovery.fsm_condition}
          />
        </div>

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
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] px-4 py-2.5">
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

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
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

function HeroPhase({ snapshot, phaseLog }: { snapshot: KeeperCompositeSnapshot; phaseLog: string[] }) {
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

  return html`
    <div class=${`rounded-xl border p-5 transition-all duration-700 ${flash ? 'border-[var(--accent)] bg-[rgba(71,184,255,0.06)] shadow-[0_0_16px_rgba(71,184,255,0.2)]' : 'border-[var(--white-8)] bg-[var(--white-2)]'}`}
      role="status" aria-live="polite" aria-label=${`Keeper phase: ${snapshot.phase}`}
    >
      <div class="flex items-baseline justify-between">
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[var(--text-muted)]" id="ksm-label">KSM · Keeper Lifecycle</div>
          <div class=${`mt-1 font-mono text-[32px] font-bold tracking-tight ${color}`} aria-labelledby="ksm-label">
            ${snapshot.phase}
          </div>
        </div>
        ${flash ? html`<span class="text-[10px] text-[var(--accent)] animate-pulse font-mono" aria-live="assertive">phase changed</span>` : null}
      </div>
      <${PhaseSparkline} log=${phaseLog} />
    </div>
  `
}

// ── Zone 3: Turn Pipeline Strip ─────────────────────────

function PipelineStep({
  label,
  shortLabel,
  value,
  isLast,
}: {
  label: string
  shortLabel: string
  value: string
  isLast?: boolean
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

  return html`
    <div class="flex items-center gap-0 flex-1 min-w-0" role="listitem" aria-label=${`${shortLabel}: ${value}`}>
      <div class=${`flex-1 rounded-lg border px-3 py-2 transition-all duration-500 ${borderCls} ${bgCls}`}>
        <div class="flex items-center gap-1.5">
          ${isActive ? html`<span class="h-1.5 w-1.5 rounded-full bg-[#818cf8] ${activePulse} shrink-0"></span>` : null}
          <span class="text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${shortLabel}</span>
        </div>
        <div class=${`mt-0.5 font-mono text-[13px] font-semibold ${isActive ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'} ${flash ? 'animate-pulse' : ''}`}>
          ${value}
        </div>
        <div class="text-[8px] text-[var(--text-dim)] mt-0.5">${label}</div>
      </div>
      ${!isLast ? html`<div class=${`hidden md:block w-5 shrink-0 ${connectorCls}`}></div>` : null}
    </div>
  `
}

function TurnPipelineStrip({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Turn Pipeline
      </div>
      <div class="flex flex-col gap-1 md:flex-row md:gap-0 md:items-stretch" role="list" aria-label="Turn pipeline stages">
        <${PipelineStep} shortLabel="KTC" label="Turn cycle" value=${snapshot.turn_phase} />
        <${PipelineStep} shortLabel="KDP" label="Decision" value=${snapshot.decision.stage} />
        <${PipelineStep} shortLabel="KCL" label="Cascade" value=${snapshot.cascade.state} />
        <${PipelineStep} shortLabel="KMC" label="Compaction" value=${snapshot.compaction.stage} isLast />
      </div>
    </div>
  `
}

// ── Zone 4: Health Grid ─────────────────────────────────

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
            <span class="text-[10px] text-[var(--text-dim)]">drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-[9px] text-[#f59e0b] mt-0.5">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="text-[10px] text-[var(--text-dim)]">관측 대기</div>
      `}
    </div>
  `
}

function Flag({ label, on, tone = 'ok' }: { label: string; on: boolean; tone?: 'ok' | 'warn' }) {
  const offCls = 'text-[var(--text-dim)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[#f59e0b] border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)]'
      : 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
  return html`
    <span class=${`rounded-full border px-2 py-0.5 text-[10px] ${on ? onCls : offCls}`}>
      ${label}
    </span>
  `
}

function InvariantsPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const entries = invariantRows(snapshot)
  const allOk = entries.every(entry => entry.ok)
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Safety
        </div>
        <span class=${`rounded-full border px-2 py-0.5 text-[9px] font-mono ${
          allOk
            ? 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
            : 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
        }`}>
          ${allOk ? '5/5' : 'violation'}
        </span>
      </div>
      <ul class="flex flex-col gap-1">
        ${entries.map(entry => html`
          <li class="flex gap-2 text-[10px]">
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
        `)}
      </ul>
    </div>
  `
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
  const borderCls = isClean ? 'border-[var(--white-8)]' : isDrift ? 'border-[rgba(239,68,68,0.3)]' : 'border-[rgba(245,158,11,0.3)]'

  return html`
    <div class=${`rounded-xl border bg-[var(--white-2)] p-3 ${borderCls}`}>
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Recovery
      </div>
      <div class=${`font-mono text-[13px] font-semibold ${toneCls}`}>${state}</div>
      <div class="mt-1.5 flex gap-3 text-[9px] text-[var(--text-dim)]">
        <span>data <span class="font-mono">${String(dataRecord)}</span></span>
        <span>fsm <span class="font-mono">${String(fsmCondition)}</span></span>
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

function TransitionTrail({
  history,
  now,
}: {
  history: { ts: number; from: string; to: string; field: string }[]
  now: number
}) {
  if (history.length === 0) {
    return html`
      <div class="rounded-lg border border-dashed border-[var(--white-8)] px-4 py-2 text-center text-[10px] text-[var(--text-dim)]">
        관찰 시작 이후 상태 전이 없음 — 전이가 발생하면 여기에 기록됩니다
      </div>
    `
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Transition History (${history.length})
      </div>
      <div class="flex flex-col gap-0.5 max-h-[120px] overflow-y-auto">
        ${history.map(entry => {
          const ago = fmtDuration(Math.max(0, now - entry.ts))
          const color = FIELD_COLOR[entry.field] ?? 'text-[var(--text-body)]'
          return html`
            <div class="flex items-center gap-2 text-[10px] font-mono leading-tight">
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
