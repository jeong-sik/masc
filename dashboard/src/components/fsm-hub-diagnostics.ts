import type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
} from '../api/keeper'

import {
  type CompositeObservation,
  type InsightTone,
  type ObservedLaneSummary,
  type OperationalInsight,
  INVARIANT_LABELS,
  LANE_LABELS,
  TRANSITION_FIELDS,
  fmtDuration,
} from './fsm-hub-types'
import { laneChangedAt, laneTransitionCount } from './fsm-hub-derivations'

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

export function invariantRows(
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
