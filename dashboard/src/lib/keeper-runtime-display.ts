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

const MODEL_PLACEHOLDERS = new Set(['unknown', 'none', '-', 'n/a', 'null', 'undefined', 'default', 'auto'])

function trimmed(value: string | null | undefined): string | null {
  const text = value?.trim()
  return text ? text : null
}

function modelText(value: string | null | undefined): string | null {
  const text = trimmed(value)
  if (!text || MODEL_PLACEHOLDERS.has(text.toLowerCase())) return null
  return text
}

function latestMetricModel(source: KeeperModelDisplaySource | null | undefined): string | null {
  const series = source?.metrics_series ?? []
  for (let index = series.length - 1; index >= 0; index -= 1) {
    const model = modelText(series[index]?.model_used)
    if (model) return model
  }
  return null
}

export function keeperDisplayModel(
  source: KeeperModelDisplaySource | null | undefined,
): KeeperModelDisplay | null {
  const lastModelLabel = modelText(source?.last_model_used_label)
  if (lastModelLabel) return { label: '최근 모델', value: lastModelLabel }

  const lastModel = modelText(source?.last_model_used)
  if (lastModel) return { label: '최근 모델', value: lastModel }

  const activeModelLabel = modelText(source?.active_model_label)
  if (activeModelLabel) return { label: '현재 모델', value: activeModelLabel }

  const activeModel = modelText(source?.active_model)
  if (activeModel) return { label: '현재 모델', value: activeModel }

  const metricModel = latestMetricModel(source)
  if (metricModel) return { label: '최근 모델', value: metricModel }

  const fallbackModel = modelText(source?.model) ?? modelText(source?.primary_model)
  if (fallbackModel) return { label: '모델', value: fallbackModel }
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
  const configured = keeper.configured_social_model?.trim()
  const fallback = keeper.social_model_fallback?.trim()
  if (configured && fallback) return `대화 모델 ${configured} 미인식 · ${fallback}로 대체 중`
  if (configured) return `대화 모델 ${configured} 미인식`
  if (fallback) return `대화 모델 fallback · ${fallback}`
  return '미인식 대화 모델 설정'
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
    return '캐스케이드 후보가 모두 소진되어 provider 상태 확인이 필요합니다.'
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
