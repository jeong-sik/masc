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
        ? 'KSM/KTC/KMC agree — 지금 누가 compaction 을 소유하는지 일치.'
        : `KSM=${snapshot.phase}, KTC=${snapshot.turn_phase}, KMC=${snapshot.compaction.stage} 가 일치하지 않음.`
    case 'no_cascade_before_measurement':
      return ok
        ? 'measurement 가 captured 된 뒤에만 cascade work 가 진행됨.'
        : `measurement.captured=${String(snapshot.measurement.captured)} 인데 KCL=${snapshot.cascade.state}.`
    case 'compaction_atomicity':
      return ok
        ? 'compaction 은 parent Compacting phase 밖에서 실행되지 않음.'
        : `KMC=${snapshot.compaction.stage} 인데 KSM=${snapshot.phase}.`
    case 'event_priority_monotone':
      return ok
        ? '이 turn 은 경쟁 measurement snapshot 을 emit 하지 않았음.'
        : '동일 turn 을 소유하려는 measurement event 가 둘 이상 등장.'
    case 'phase_derivation_agreement': {
      const diag = snapshot.phase_diagnosis
      if (ok) return '저장된 KSM phase 와 derive_phase(conditions) 결과가 일치.'
      return diag
        ? `current=${diag.current_phase}, derived=${diag.derived_phase} 불일치 — KSM 상태 drift.`
        : 'KSM 저장 phase 와 derive_phase(conditions) 결과가 불일치.'
    }
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
    case 'routing':
      return 'cascade routing 이 완료되면 KCL 이 trying 으로 진행해야 함.'
    case 'executing':
      return 'execution 은 turn 을 finalize 하거나 cascade/compaction transition 을 유도해야 함.'
    case 'compacting':
      return 'turn finalization 이 compaction 종료를 대기 중.'
    case 'finalizing':
      return '다음 stable state 는 last_outcome 갱신된 idle 이어야 함.'
    case 'exhausted':
      return 'cascade 가 소진됨. 다음 관측에서 idle 또는 retry 로 전이해야 함.'
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
      ? ` raw keeper phase is ${snapshot.collapsed_from} — 이건 단순한 idleness 가 아님.`
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
        ? `sub-FSM 들이 idle placeholder 로 fallback 됨; 마지막 완료 turn 은 ${idleSince} 전 종료.`
        : 'observer 가 idle — has not captured a completed turn yet.',
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
