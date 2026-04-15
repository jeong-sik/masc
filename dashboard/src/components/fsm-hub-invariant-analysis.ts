import type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
} from '../api/keeper'

import {
  type CompositeObservation,
  type ObservedLaneSummary,
  type OperationalInsight,
  INVARIANT_LABELS,
  fmtDuration,
} from './fsm-hub-types'
import { deriveObservedLaneSummaries } from './fsm-hub-lane-analysis'

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
  if (snapshot.phase === 'Overflowed') {
    return 'Context overflow must resolve through compaction or explicit operator clearance before the lifecycle can settle.'
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
  if (snapshot.phase === 'Stable') {
    return 'The lifecycle is outside the active turn cycle; the next meaningful edge should come from a new live turn or operator action.'
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
  precomputedLanes?: ObservedLaneSummary[],
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

  const lanes = precomputedLanes ?? deriveObservedLaneSummaries(snapshot, observations, now)
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
  if (snapshot.phase === 'Overflowed' || snapshot.phase === 'HandingOff' || snapshot.phase === 'Draining' || snapshot.phase === 'Stable') {
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
