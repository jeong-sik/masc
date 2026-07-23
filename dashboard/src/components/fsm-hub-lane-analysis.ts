import type { KeeperCompositeSnapshot } from '../api/keeper'

import {
  type CompositeObservation,
  type InsightTone,
  type LaneKey,
  type ObservedLaneSummary,
  LANE_LABELS,
  TRANSITION_FIELDS,
  extractLaneValue,
} from './fsm-hub-types'
import { laneChangedAt, laneTransitionCount } from './fsm-hub-derivations'

export function isObservedStall(
  key: LaneKey,
  value: string,
  observedForSec: number,
): boolean {
  if (key === 'phase') {
    // Wire format from `phase_to_string` (lib/keeper/keeper_state_machine.ml:21-35)
    // is lowercase + snake_case. Prior PascalCase compares never matched —
    // KSM stalled detection silently disabled for every non-terminal phase.
    if (value === 'failing') return observedForSec >= 90
    if (value === 'overflowed') return observedForSec >= 60
    if (value === 'compacting') return observedForSec >= 90
    if (value === 'handing_off' || value === 'draining') return observedForSec >= 60
    return false
  }
  if (key === 'turn') {
    if (value === 'prompting' || value === 'executing') return observedForSec >= 45
    if (value === 'compacting') return observedForSec >= 60
    if (value === 'finalizing') return observedForSec >= 30
    return false
  }
  if (key === 'runtime') {
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
  key: LaneKey,
  snapshot: KeeperCompositeSnapshot,
  observedForSec: number,
): { tone: InsightTone; meaning: string } {
  const value = extractLaneValue(snapshot, key)

  const base: { tone: InsightTone; meaning: string } = (() => {
    switch (key) {
    case 'phase':
      // Wire format from `phase_to_string` (lib/keeper/keeper_state_machine.ml:21-35)
      // is lowercase + snake_case. PascalCase cases ('Stable' was the
      // 7-phase composite projection per KeeperCompositeLifecycle.tla:143,
      // never emitted by the backend; remove rather than carry the dead
      // arm).
      switch (value) {
        case 'running':
          return snapshot.is_live
            ? { tone: 'info', meaning: 'parent lifecycle 정상 — live turn 진행 중' }
            : { tone: 'ok', meaning: 'keeper 는 살아있고 현재 진행 중인 turn 은 없음' }
        case 'failing':
          return { tone: 'error', meaning: 'parent lifecycle degraded — healthy turn 재개 전 해소 필요' }
        case 'overflowed':
          return { tone: 'warn', meaning: 'context overflow latched — healthy turn 재개 전 해소 필요' }
        case 'compacting':
          return { tone: 'warn', meaning: 'post-turn compaction 이 lifecycle 점유 중' }
        case 'handing_off':
          return { tone: 'warn', meaning: 'handoff 가 keeper 를 stop 방향으로 drain 중' }
        case 'draining':
          return { tone: 'warn', meaning: 'keeper 가 in-flight work 를 drain 중 (stop 전)' }
        default:
          return { tone: 'info', meaning: 'lifecycle state 관측됨' }
      }
    case 'turn':
      switch (value) {
        case 'idle':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'turn context 존재하지만 work 미진행' : '현재 진행 중인 turn 없음' }
        case 'prompting':
          return { tone: 'info', meaning: 'prompt assembly 가 turn input 준비 중' }
        case 'executing':
          return { tone: 'info', meaning: 'turn 이 model/tool execution work 안에 있음' }
        case 'compacting':
          return { tone: 'warn', meaning: 'turn finalization 이 compaction 종료 대기 중' }
        case 'finalizing':
          return { tone: 'info', meaning: 'turn 이 결과 seal + 다음 idle snapshot 준비 중' }
        default:
          return { tone: 'info', meaning: 'turn-cycle state 관측됨' }
      }
    case 'decision':
      switch (value) {
        case 'undecided':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'decision work 미커밋' : '진행 중인 turn 이 없어 결정 단계 없음' }
        case 'guard_ok':
          return { tone: 'info', meaning: 'guardrail 통과 — turn 계속 진행 허용' }
        case 'tool_policy_selected':
          return { tone: 'info', meaning: '도구 목록 선택 커밋됨 — execution 진행 가능' }
        default:
          return { tone: 'info', meaning: 'decision state 관측됨' }
      }
    case 'runtime':
      switch (value) {
        case 'idle':
          return { tone: 'ok', meaning: 'provider/runtime 실행 중 아님' }
        case 'selecting':
          return { tone: 'info', meaning: 'provider routing 이 다음 execution path 선택 중' }
        case 'trying':
          return { tone: 'info', meaning: 'provider execution 진행 중' }
        case 'done':
          return { tone: 'ok', meaning: 'runtime 가 이번 turn 의 provider 결과 수락' }
        case 'exhausted':
          return { tone: 'error', meaning: 'runtime 옵션 모두 소진 — 사용 가능한 path 없음' }
        default:
          return { tone: 'info', meaning: 'runtime state 관측됨' }
      }
    case 'compaction':
      switch (value) {
        case 'accumulating':
          return { tone: 'ok', meaning: '메모리 누적 중 — compaction 실행 중 아님' }
        case 'compacting':
          return { tone: 'warn', meaning: 'memory compaction 이 context state 를 rewrite 중' }
        case 'done':
          return { tone: 'ok', meaning: '관측된 turn 의 compaction 완료' }
        default:
          return { tone: 'info', meaning: 'compaction state 관측됨' }
      }
    }
  })()

  if (base.tone !== 'error' && isObservedStall(key, value, observedForSec)) {
    return { tone: 'warn', meaning: 'state movement 이 이 화면에서 정체된 것으로 보임' }
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
    const value = extractLaneValue(snapshot, key)
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
