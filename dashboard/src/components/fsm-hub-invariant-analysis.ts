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
  }
}

function nextExpectedStep(snapshot: KeeperCompositeSnapshot): string {
  const collapsedFrom = snapshot.phase === 'Stable' ? snapshot.collapsed_from : null
  if (!snapshot.is_live) {
    return snapshot.last_outcome
      ? '다음 live turn 이 idle placeholder 로부터 KTC/KDP/KCL 을 repopulate 해야 함.'
      : '아직 완료된 턴 없음 — first live turn 이 observer 를 채워야 함.'
  }
  if (snapshot.phase === 'Failing' && snapshot.cascade.state === 'exhausted') {
    return '정상 provider path 또는 명시적 recovery clearance 가 Failing 을 해제해야 Running 재개 가능.'
  }
  if (snapshot.phase === 'Overflowed') {
    return 'context overflow 은 compaction 또는 명시적 operator clearance 로 해소되어야 lifecycle 이 정착 가능.'
  }
  if (snapshot.phase === 'Compacting' || snapshot.compaction.stage === 'compacting') {
    return 'KMC 가 done 에 도달한 뒤 KSM 이 Running 으로 control 을 반환해야 함.'
  }
  if (snapshot.phase === 'HandingOff') {
    return 'handoff completion 이 관측되면 현재 keeper 는 stop 해야 함.'
  }
  if (snapshot.phase === 'Draining') {
    return 'lifecycle 가 Stopped 로 정착되기 전에 Draining 이 완료되어야 함.'
  }
  if (snapshot.phase === 'Stable') {
    return collapsedFrom
      ? `lifecycle 가 raw phase ${collapsedFrom} 에서 Stable 로 collapse 됨; 다음 meaningful edge 가 turn activity 재개 전에 그 underlying condition 을 clear 해야 함.`
      : 'lifecycle 가 active turn cycle 밖에 있음; 다음 meaningful edge 는 새 live turn 또는 operator action 에서 시작되어야 함.'
  }
  if (snapshot.decision.stage === 'gate_rejected') {
    return 'blocked turn 은 cascade/tool execution 진입 없이 idle 로 finalize 되어야 함.'
  }
  if (snapshot.cascade.state === 'selecting' || snapshot.cascade.state === 'trying') {
    return 'provider routing 이 반환되면 KCL 이 done 또는 exhausted 로 정착해야 함.'
  }
  switch (snapshot.turn_phase) {
    case 'prompting':
      return 'prompt assembly 완료 시 KTC 가 executing 으로 진행해야 함.'
    case 'executing':
      return 'execution 은 turn 을 finalize 하거나 cascade/compaction transition 을 유도해야 함.'
    case 'compacting':
      return 'turn finalization 이 compaction 종료를 대기 중.'
    case 'finalizing':
      return '다음 stable state 는 last_outcome 갱신된 idle 이어야 함.'
    default:
      return '다음 meaningful edge 는 다음 관측된 lifecycle event 에서 시작되어야 함.'
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
      headline: `Spec drift 감지: ${INVARIANT_LABELS[brokenInvariant]}`,
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
  if (snapshot.phase === 'Failing' && snapshot.cascade.state === 'exhausted') {
    return {
      tone: 'error',
      headline: 'cascade exhaustion 후 실패',
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
      headline: 'Guardrail 가 턴 차단',
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
      headline: `${stalledLane.field} 정체 — not moving`,
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
      headline: 'Compaction 가 현재 턴 소유',
      detail: 'The parent lifecycle and memory lane both indicate that post-turn compaction is the active coordination point.',
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        `KMC ${snapshot.compaction.stage}`,
      ],
    }
  }
  if (snapshot.phase === 'Overflowed' || snapshot.phase === 'HandingOff' || snapshot.phase === 'Draining' || snapshot.phase === 'Stable') {
    const collapsedDetail = snapshot.phase === 'Stable' && snapshot.collapsed_from
      ? ` The raw keeper phase is ${snapshot.collapsed_from}, so this is not just generic idleness.`
      : ''
    return {
      tone: 'warn',
      headline: `${snapshot.phase} 가 활성 lifecycle edge`,
      detail: `The keeper is transitioning between stable lifecycle states, so the parent FSM matters more than sub-turn activity right now.${collapsedDetail}`,
      nextStep: nextExpectedStep(snapshot),
      evidence: [
        `KSM ${snapshot.phase}`,
        ...(snapshot.collapsed_from ? [`raw ${snapshot.collapsed_from}`] : []),
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
      headline: 'Idle 스냅샷 정상',
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
      headline: 'Provider 작업이 활성 frontier',
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
    headline: '라이브 턴 progressing normally',
    detail: 'No invariant drift is visible; the sub-FSMs look aligned for the current live turn.',
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
