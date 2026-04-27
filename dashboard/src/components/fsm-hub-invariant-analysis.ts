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
      ? 'The next live turn should repopulate KTC/KDP/KCL from idle placeholders.'
      : '아직 완료된 턴 없음 — first live turn 이 observer 를 채워야 함.'
  }
  if (snapshot.phase === 'Failing' && snapshot.cascade.state === 'exhausted') {
    return '정상 provider path 또는 명시적 recovery clearance 가 Failing 을 해제해야 Running 재개 가능.'
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
    return collapsedFrom
      ? `The lifecycle is collapsed into Stable from raw phase ${collapsedFrom}; the next meaningful edge should clear that underlying condition before turn activity resumes.`
      : 'The lifecycle is outside the active turn cycle; the next meaningful edge should come from a new live turn or operator action.'
  }
  if (snapshot.decision.stage === 'gate_rejected') {
    return 'blocked turn 은 cascade/tool execution 진입 없이 idle 로 finalize 되어야 함.'
  }
  if (snapshot.cascade.state === 'selecting' || snapshot.cascade.state === 'trying') {
    return 'KCL should settle into done or exhausted once provider routing returns.'
  }
  switch (snapshot.turn_phase) {
    case 'prompting':
      return 'prompt assembly 완료 시 KTC 가 executing 으로 진행해야 함.'
    case 'executing':
      return 'Execution should either finalize the turn or drive cascade/compaction transitions.'
    case 'compacting':
      return 'Turn finalization is waiting on compaction to finish.'
    case 'finalizing':
      return '다음 stable state 는 last_outcome 갱신된 idle 이어야 함.'
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
      detail: 'keeper 가 남은 cascade path 없이 recovery 에 진입 — turn 이 provider failover 로 self-heal 불가능.',
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
      detail: 'decision pipeline 이 gate_rejected 에 도달 — execution 은 provider work 진입 없이 unwind 되어야 함.',
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
      detail: `${stalledLane.value} 가 ${fmtDuration(stalledLane.observedForSec)} 동안 새 edge 없이 이 화면에서 관측됨.`,
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
      detail: 'parent lifecycle 과 memory lane 모두 post-turn compaction 이 active coordination point 임을 가리킴.',
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
      detail: `keeper 가 stable lifecycle state 사이를 transitioning 중 — 지금은 parent FSM 이 sub-turn activity 보다 우선.${collapsedDetail}`,
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
      detail: 'cascade 가 live turn 의 ownership 을 가져감 — 중요한 next edge 는 provider completion 또는 exhaustion.',
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
    detail: 'invariant drift 보이지 않음 — sub-FSM 들이 현재 live turn 에 대해 aligned.',
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
