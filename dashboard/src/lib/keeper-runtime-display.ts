import type { Keeper, KeeperRuntimeBlockerClass } from '../types'
import { relativeTime } from './format-time'

/** Max seconds since last heartbeat to consider the keeper process alive. */
const HEARTBEAT_ALIVE_THRESHOLD_S = 120

export type KeeperActivitySource =
  | 'autonomous_action'
  | 'heartbeat'
  | 'last_activity'
  | 'last_turn'
  | 'agent_seen'
  | 'created'
  | 'none'

export interface KeeperActivityDisplay {
  source: KeeperActivitySource
  label: string
  timestamp: string | null
  ageSeconds: number | null
}

interface KeeperModelDisplay {
  label: string
  value: string
}

type KeeperModelDisplaySource = {
  last_model_used_label?: string | null
  last_model_used?: string | null
  active_model_label?: string | null
  active_model?: string | null
  model?: string | null
  primary_model?: string | null
  metrics_series?: Array<{ model_used?: string | null } | null> | null
}

type KeeperActivityDisplaySource = {
  last_autonomous_action_at?: string | null
  last_heartbeat?: string | null
  last_activity_ago_s?: number | null
  last_turn_ago_s?: number | null
  created_at?: string | null
}

type ActivityCandidate = {
  source: KeeperActivitySource
  label: string
  timestamp: string | null
  ageSeconds: number
}

function trimmed(value: string | null | undefined): string | null {
  const text = value?.trim()
  return text ? text : null
}

export function keeperDisplayModel(
  _source: KeeperModelDisplaySource | null | undefined,
): KeeperModelDisplay | null {
  return null
}

function timestampCandidate(
  source: KeeperActivitySource,
  label: string,
  timestamp: string | null | undefined,
): ActivityCandidate | null {
  const value = trimmed(timestamp)
  if (!value) return null
  const ms = Date.parse(value)
  if (Number.isNaN(ms)) return null
  return {
    source,
    label,
    timestamp: value,
    ageSeconds: Math.max(0, Math.round((Date.now() - ms) / 1000)),
  }
}

function ageCandidate(
  source: KeeperActivitySource,
  label: string,
  ageSeconds: number | null | undefined,
): ActivityCandidate | null {
  if (typeof ageSeconds !== 'number' || !Number.isFinite(ageSeconds) || ageSeconds < 0) return null
  return {
    source,
    label,
    timestamp: null,
    ageSeconds: Math.round(ageSeconds),
  }
}

export function keeperActivityDisplay(
  keeper: KeeperActivityDisplaySource | null | undefined,
  fallbackAgentLastSeen?: string | null,
): KeeperActivityDisplay {
  const candidates = [
    timestampCandidate('autonomous_action', '마지막 행동', keeper?.last_autonomous_action_at),
    timestampCandidate('heartbeat', '하트비트', keeper?.last_heartbeat),
    ageCandidate('last_activity', '최근 활동', keeper?.last_activity_ago_s),
    ageCandidate('last_turn', '마지막 턴', keeper?.last_turn_ago_s),
  ].filter((candidate): candidate is ActivityCandidate => candidate != null)

  candidates.sort((left, right) => left.ageSeconds - right.ageSeconds)
  const freshest = candidates[0]
  if (freshest) return freshest

  const agentSeen = timestampCandidate('agent_seen', '에이전트 신호', fallbackAgentLastSeen)
  if (agentSeen) return agentSeen

  const created = timestampCandidate('created', '생성', keeper?.created_at)
  if (created) return created

  return {
    source: 'none',
    label: '최근 활동',
    timestamp: null,
    ageSeconds: null,
  }
}

export function keeperDisplayStatus(keeper: Keeper | null | undefined, fallbackStatus?: string | null): string {
  if (keeper?.paused) return 'paused'
  const status = keeper?.status ?? fallbackStatus
  const normalized = (status ?? '').trim().toLowerCase()

  // Refine generic offline/inactive into specific sub-states
  if (normalized === 'offline' || normalized === 'inactive') {
    return refineOfflineStatus(keeper)
  }

  return status && status.trim() !== '' ? status : 'unknown'
}

/** Distinguish "never booted" from "was running but stopped" keepers.
 *  Reconciles heartbeat liveness with agent registration status:
 *  if heartbeat is recent but agent is offline, shows phase instead of "offline". */
function refineOfflineStatus(keeper: Keeper | null | undefined): string {
  if (!keeper) return 'offline'

  // Heartbeat alive but agent offline — keepalive fiber is running.
  // Show actual phase instead of misleading "offline".
  if (keeper.last_heartbeat && isHeartbeatAlive(keeper.last_heartbeat)) {
    const phase = keeper.phase?.trim().toLowerCase()
    if (phase && phase !== 'offline' && phase !== 'inactive') return phase
    return 'idle'
  }

  const generation = keeper.generation ?? 0
  const turnCount = keeper.turn_count ?? 0
  const agentExists = keeper.agent?.exists ?? false

  // Never ran a single turn or generation — registered but never booted
  if (generation === 0 && turnCount === 0 && !agentExists) {
    return 'unbooted'
  }

  // Had activity before but now offline — stopped/crashed
  if (generation > 0 || turnCount > 0) {
    return 'stopped'
  }

  return 'offline'
}

function isHeartbeatAlive(heartbeat: string): boolean {
  const ts = new Date(heartbeat).getTime()
  if (Number.isNaN(ts)) return false
  return (Date.now() - ts) / 1000 < HEARTBEAT_ALIVE_THRESHOLD_S
}

function socialModelFallbackHint(keeper: Keeper): string | null {
  if (keeper.social_model_recognized !== false) return null
  return '대화 런타임 설정 확인 필요'
}

function continueGateHint(keeper: Keeper): string {
  const detail = keeper.runtime_blocker_summary?.trim()
  if (detail) return `계속 진행 승인 대기 · ${detail}`
  if (keeper.runtime_blocker_class === 'ambiguous_post_commit_timeout') {
    return '계속 진행 승인 대기 · 변경 이후 응답이 끊겨 상태 확인이 필요합니다.'
  }
  if (keeper.runtime_blocker_class === 'ambiguous_post_commit_failure') {
    return '계속 진행 승인 대기 · 변경 이후 실패가 있어 상태 확인이 필요합니다.'
  }
  return '계속 진행 승인 대기 · 일부 변경이 반영되었을 수 있어 운영자 확인이 필요합니다.'
}

const runtimeBlockerLabels = {
  ambiguous_post_commit_timeout: '커밋 후 응답 없음',
  ambiguous_post_commit_failure: '커밋 후 실패',
  autonomous_slot_wait_timeout: '자율 슬롯 대기 만료',
  admission_queue_wait_timeout: '대기열 진입 만료',
  turn_timeout_after_queue_wait: '대기 후 턴 만료',
  oas_timeout_budget: 'OAS 응답 만료',
  turn_timeout: '턴 응답 만료',
  completion_contract_violation: '완료 계약 위반',
  cascade_exhausted: '캐스케이드 소진',
  no_tool_capable_provider: '도구 실행 Provider 없음',
  provider_runtime_error: 'Provider 런타임 오류',
  tool_required_unsatisfied: '필수 도구 미충족',
  fiber_unresolved: 'Fiber 미해결',
  stale_turn_timeout: '오래된 턴 만료',
  stale_termination_storm: 'Stale 종료 폭주',
  heartbeat_failures: '하트비트 실패',
  turn_failures: '턴 실패 반복',
  exception: '런타임 예외',
  stale_fleet_batch: 'Fleet stale 배치',
  awaiting_operator: '운영자 조치 대기',
  awaiting_sandbox_egress: '샌드박스 egress 대기',
  supervisor_paused: 'Supervisor 일시정지',
  synthetic_stall: '합성 상태 정체',
  self_imposed_idle: '자체 대기',
  sdk_max_turns_exceeded: 'SDK 최대 턴 초과',
  sdk_token_budget_exceeded: 'SDK 토큰 예산 초과',
  sdk_cost_budget_exceeded: 'SDK 비용 예산 초과',
  sdk_unrecognized_stop_reason: 'SDK 미식별 정지 사유',
  sdk_idle_detected: 'SDK Idle 감지',
  sdk_tool_retry_exhausted: 'SDK 도구 재시도 소진',
  sdk_guardrail_violation: 'SDK 가드레일 위반',
  sdk_tripwire_violation: 'SDK Tripwire 위반',
  sdk_exit_condition_met: 'SDK 종료 조건 충족',
} satisfies Record<KeeperRuntimeBlockerClass, string>

export function keeperRuntimeBlockerLabel(
  blockerClass: Keeper['runtime_blocker_class'] | null | undefined,
): string | null {
  if (!blockerClass) return null
  return runtimeBlockerLabels[blockerClass] ?? null
}

export function keeperRuntimeBlockerHint(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  if (keeper.runtime_blocker_continue_gate) return continueGateHint(keeper)
  const blockerClass = keeper.runtime_blocker_class
  const runtimeBlocker = keeper.runtime_blocker_summary?.trim()
  if (runtimeBlocker && runtimeBlocker !== blockerClass) return runtimeBlocker
  if (blockerClass === 'ambiguous_post_commit_timeout') {
    return '최근 변경 이후 응답이 끊겨 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'ambiguous_post_commit_failure') {
    return '최근 변경 이후 실패가 있어 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'autonomous_slot_wait_timeout') {
    return '자율 턴이 실행 슬롯을 기다리다 타임아웃되었습니다.'
  }
  if (blockerClass === 'admission_queue_wait_timeout') {
    return 'OAS admission queue 대기 시간이 초과되었습니다.'
  }
  if (blockerClass === 'turn_timeout_after_queue_wait') {
    return '대기 후 실행된 턴이 전체 제한 시간을 초과했습니다.'
  }
  if (blockerClass === 'oas_timeout_budget') {
    return 'OAS 실행 예산이 먼저 소진되었습니다.'
  }
  if (blockerClass === 'turn_timeout') {
    return '턴 실행 시간이 제한 시간을 초과했습니다.'
  }
  if (blockerClass === 'completion_contract_violation') {
    return '완료 계약 조건을 만족하지 못해 재확인이 필요합니다.'
  }
  if (blockerClass === 'cascade_exhausted') {
    return '캐스케이드 후보가 모두 소진되어 runtime 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'no_tool_capable_provider') {
    return '요구 도구를 실행할 수 있는 provider가 없어 라우팅 또는 tool surface 확인이 필요합니다.'
  }
  if (blockerClass === 'provider_runtime_error') {
    return 'Provider, adapter, or cascade가 keeper 진행 전에 실패했습니다.'
  }
  if (blockerClass === 'tool_required_unsatisfied') {
    return '액션 가능한 신호에 필요한 keeper 도구 호출이 충족되지 않았습니다.'
  }
  if (blockerClass === 'fiber_unresolved') {
    return 'Keeper fiber가 종료 상태를 확정하지 못해 supervisor 확인이 필요합니다.'
  }
  if (blockerClass === 'stale_turn_timeout') {
    return '오래된 턴 제한 시간이 만료되어 최신 실행 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'stale_termination_storm') {
    return 'Stale watchdog 종료가 반복되어 restart 전에 원인 확인이 필요합니다.'
  }
  if (blockerClass === 'heartbeat_failures') {
    return '하트비트 실패가 누적되어 keeper 생존 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'turn_failures') {
    return '턴 실패가 반복되어 최근 실행 오류 확인이 필요합니다.'
  }
  if (blockerClass === 'exception') {
    return 'Keeper 런타임 예외가 기록되어 로그와 최근 turn 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'stale_fleet_batch') {
    return '여러 keeper가 같은 watchdog 창에서 stale로 종료되어 supervisor pause/backoff 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'awaiting_operator') {
    return '진행을 위해 운영자의 승인, 결정, 또는 게이트 해제가 필요합니다.'
  }
  if (blockerClass === 'awaiting_sandbox_egress') {
    return '샌드박스 네트워크 또는 push egress 정책 때문에 keeper가 진행하지 못하고 있습니다.'
  }
  if (blockerClass === 'supervisor_paused') {
    return 'Supervisor가 keeper를 일시정지한 상태라 재개 조건을 확인해야 합니다.'
  }
  if (blockerClass === 'synthetic_stall') {
    return '실제 STATE 없이 합성된 진행 기록만 남아 최근 턴 산출물을 재확인해야 합니다.'
  }
  if (blockerClass === 'self_imposed_idle') {
    return 'Keeper가 관찰 또는 대기만 계획하고 있어 다음 실행 지시가 필요할 수 있습니다.'
  }
  return null
}

export function keeperRecentHeartbeatLabel(keeper: Keeper | null | undefined): string {
  return keeper?.last_heartbeat
    ? `최근 하트비트 · ${relativeTime(keeper.last_heartbeat)}`
    : '최근 하트비트 · 기록 없음'
}

export function keeperRecentActionLabel(
  keeper: Keeper | null | undefined,
  fallbackLastTurnAgoS?: number | null,
): string | null {
  if (keeper?.last_autonomous_action_at) {
    return `마지막 행동 · ${relativeTime(keeper.last_autonomous_action_at)}`
  }
  const seconds = keeper?.last_turn_ago_s ?? fallbackLastTurnAgoS
  return typeof seconds === 'number' && Number.isFinite(seconds)
    ? `마지막 턴 · ${Math.round(seconds)}초 전`
    : null
}

export function keeperRuntimeHint(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  if (runtimeBlocker) return runtimeBlocker
  const socialFallback = socialModelFallbackHint(keeper)
  if (socialFallback) return socialFallback
  const blocker = keeper.last_blocker?.trim()
  if (keeper.paused && blocker) return `일시정지 · ${blocker}`
  if (keeper.paused && keeper.keepalive_running) return '일시정지 · 하트비트만 유지 중'
  if (keeper.paused) return '일시정지됨'
  if (blocker) return `차단 요인 · ${blocker}`
  return null
}
