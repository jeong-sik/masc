import type { Keeper, KeeperRuntimeBlockerClass } from '../types'
import { relativeTime } from './format-time'
import { firstNonEmptyString } from './format-string'
import { isKeeperPaused } from './keeper-predicates'

/** Max seconds since last heartbeat to consider the keeper process alive. */
const HEARTBEAT_ALIVE_THRESHOLD_S = 120

export type KeeperActivitySource =
  | 'autonomous_action'
  | 'heartbeat'
  | 'keeper_meta'
  | 'tool_call'
  | 'approval_pending'
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

interface KeeperActivityDisplayOptions {
  includeCreated?: boolean
}

interface KeeperModelDisplay {
  label: string
  value: string
}

interface KeeperRuntimeDisplay {
  label: string
  value: string
}

export interface KeeperPauseDisplay {
  reason: string
  nextAction: string | null
  diagnostic: string | null
  detail: string
  title: string
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

type KeeperRuntimeDisplaySource = {
  runtime_id?: string | null
  runtime_ref?: { group?: string | null; item?: string | null } | null
  runtime_canonical?: string | null
  selected_runtime_canonical?: string | null
}

type KeeperActivityDisplaySource = {
  last_autonomous_action_at?: string | null
  last_heartbeat?: string | null
  last_activity_at?: string | null
  last_activity_source?: Keeper['last_activity_source'] | null
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

const NO_PROGRESS_LOOP_HINT =
  '반복된 무증거 턴으로 자동 정지된 progress-safety latch입니다. provider 실패가 아니며 Resume이 latch를 해제합니다.'
const IDLE_LOOP_HINT =
  '반복 idle 턴으로 자동 정지되었습니다. provider 실패가 아니며 최근 실행 상태 확인 후 재개하세요.'

export function normalizeKeeperBlockerText(value: string | null | undefined): string | null {
  const text = trimmed(value)
  if (!text) return null
  const lower = text.toLowerCase()
  if (lower.includes('no_progress loop detected') || lower.includes('no-progress loop')) {
    return NO_PROGRESS_LOOP_HINT
  }
  if (lower.includes('idle loop detected')) return IDLE_LOOP_HINT
  return text
}

export function keeperDisplayModel(
  _source: KeeperModelDisplaySource | null | undefined,
): KeeperModelDisplay | null {
  return null
}

export function keeperDisplayRuntime(
  source: KeeperRuntimeDisplaySource | null | undefined,
): KeeperRuntimeDisplay | null {
  const canonical = firstNonEmptyString(
    source?.runtime_canonical,
    source?.selected_runtime_canonical,
  )
  if (canonical) return { label: 'Runtime', value: canonical }

  const runtimeId = trimmed(source?.runtime_id)
  if (runtimeId) return { label: 'Runtime', value: runtimeId }

  const group = trimmed(source?.runtime_ref?.group)
  if (!group) return null
  const item = trimmed(source?.runtime_ref?.item)
  return { label: 'Runtime', value: item ? `${group}.${item}` : group }
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

function activitySourceLabel(source: Keeper['last_activity_source'] | null | undefined): string {
  switch (source) {
    case 'approval_pending':
      return '승인 대기'
    case 'tool_call':
      return '도구 활동'
    case 'keeper_meta':
      return '최근 활동'
    case null:
    case undefined:
      return '최근 활동'
  }
}

function activityDisplaySource(source: Keeper['last_activity_source'] | null | undefined): KeeperActivitySource {
  switch (source) {
    case 'approval_pending':
      return 'approval_pending'
    case 'tool_call':
      return 'tool_call'
    case 'keeper_meta':
      return 'keeper_meta'
    case null:
    case undefined:
      return 'last_activity'
  }
}

export function keeperActivityDisplay(
  keeper: KeeperActivityDisplaySource | null | undefined,
  fallbackAgentLastSeen?: string | null,
  options: KeeperActivityDisplayOptions = {},
): KeeperActivityDisplay {
  const includeCreated = options.includeCreated !== false
  const candidates = [
    timestampCandidate(
      activityDisplaySource(keeper?.last_activity_source),
      activitySourceLabel(keeper?.last_activity_source),
      keeper?.last_activity_at,
    ),
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

  if (includeCreated) {
    const created = timestampCandidate('created', '생성', keeper?.created_at)
    if (created) return created
  }

  return {
    source: 'none',
    label: '최근 활동',
    timestamp: null,
    ageSeconds: null,
  }
}

export function keeperDisplayStatus(keeper: Keeper | null | undefined, fallbackStatus?: string | null): string {
  if (keeper && isKeeperPaused(keeper)) return 'paused'
  const lifecycleStatus = keeperLifecycleStatus(keeper?.lifecycle_phase)
  // Honor the FSM phase first: a Running keeper whose status field says
  // 'idle' should still read as running, not collapse to idle.
  if (lifecycleStatus) return lifecycleStatus
  const status = keeper?.status ?? fallbackStatus
  const normalized = (status ?? '').trim().toLowerCase()

  // Refine generic offline/inactive into specific sub-states
  if (normalized === 'offline' || normalized === 'inactive') {
    return refineOfflineStatus(keeper)
  }

  return status && status.trim() !== '' ? status : 'unknown'
}

function keeperLifecycleStatus(phase: Keeper['lifecycle_phase'] | string | null | undefined): string | null {
  switch (phase) {
    case 'Offline':
      return 'unbooted'
    case 'Running':
      return 'running'
    case 'Failing':
      return 'failing'
    case 'Overflowed':
      return 'overflowed'
    case 'Compacting':
      return 'compacting'
    case 'HandingOff':
      return 'handoff'
    case 'Draining':
      return 'draining'
    case 'Paused':
      return 'paused'
    case 'Stopped':
      return 'stopped'
    case 'Crashed':
      return 'crashed'
    case 'Restarting':
      return 'restarting'
    case 'Dead':
      return 'dead'
    case 'Zombie':
      return 'zombie'
    default:
      return null
  }
}

function codeLabel(value: string | null | undefined): string | null {
  const text = trimmed(value)
  return text ? text.replace(/_/g, ' ') : null
}

function attentionReasonForPause(value: string | null | undefined): string | null {
  const text = trimmed(value)
  if (!text || text === 'paused') return null
  return codeLabel(text)
}

function diagnosticStateLabel(keeper: Keeper): string | null {
  const health = codeLabel(keeper.diagnostic?.health_state)
  const continuity = codeLabel(keeper.diagnostic?.continuity_state)
  if (health && continuity && health !== continuity) return `${health}/${continuity}`
  return health ?? continuity
}

function transientProviderRuntimeText(value: string | null | undefined): boolean {
  const text = value?.trim().toLowerCase()
  if (!text) return false
  return (
    text.includes('tls alert')
    || text.includes('tls_error')
    || text.includes('handshake failure')
    || text.includes('network')
    || text.includes('connection refused')
    || text.includes('connection reset')
    || text.includes('dns')
    || text.includes('timeout')
    || text.includes('timed out')
  )
}

export function isKeeperAutoRecoverPause(keeper: Keeper | null | undefined): boolean {
  if (!keeper || !isKeeperPaused(keeper)) return false
  const blockerClass = keeper.runtime_blocker_class
  if (
    blockerClass === 'turn_timeout'
    || blockerClass === 'turn_timeout_after_queue_wait'
    || blockerClass === 'admission_queue_wait_timeout'
  ) {
    return true
  }
  if (blockerClass === 'provider_runtime_error') {
    return (
      transientProviderRuntimeText(keeper.runtime_blocker_summary)
      || transientProviderRuntimeText(keeper.last_blocker)
      || transientProviderRuntimeText(keeper.attention_reason)
    )
  }
  return false
}

export function keeperPauseDisplay(keeper: Keeper): KeeperPauseDisplay | null {
  if (!isKeeperPaused(keeper)) return null
  const autoRecover = isKeeperAutoRecoverPause(keeper)
  const trust = keeper.trust
  const blockerLabel = keeperRuntimeBlockerLabel(keeper.runtime_blocker_class)
  const reason =
    blockerLabel
    ?? attentionReasonForPause(keeper.attention_reason)
    ?? attentionReasonForPause(trust?.attention_reason)
    ?? firstNonEmptyString(
      keeper.runtime_blocker_summary,
      trust?.latest_terminal_reason?.summary,
      keeper.diagnostic?.continuity_summary,
      keeper.diagnostic?.summary,
    )
    ?? '운영자 일시정지'
  const nextAction = firstNonEmptyString(
    codeLabel(keeper.next_human_action),
    codeLabel(trust?.next_human_action),
    codeLabel(trust?.latest_next_action),
    codeLabel(trust?.latest_terminal_reason?.next_action),
    codeLabel(keeper.diagnostic?.next_action_path),
  )
  const diagnostic = diagnosticStateLabel(keeper)
  const detail = [
    autoRecover ? '상태 자동 재시도 대기' : null,
    `원인 ${reason}`,
    nextAction ? `다음 ${nextAction}` : autoRecover ? '다음 자동 재시도' : null,
    diagnostic ? `진단 ${diagnostic}` : null,
  ].filter((part): part is string => part !== null).join(' · ')
  const title = [
    detail,
    `paused=${keeper.paused === true ? 'true' : 'false'}`,
    `phase=${keeper.phase ?? 'unknown'}`,
    `status=${keeper.status ?? 'unknown'}`,
    `pipeline=${keeper.pipeline_stage ?? 'unknown'}`,
  ].join(' · ')
  return {
    reason,
    nextAction,
    diagnostic,
    detail,
    title,
  }
}

/** Distinguish "never booted" from "was running but stopped" keepers.
 *  Reconciles heartbeat liveness with agent registration status:
 *  if heartbeat is recent but agent is offline, shows phase instead of "offline". */
function refineOfflineStatus(keeper: Keeper | null | undefined): string {
  if (!keeper) return 'offline'

  // Heartbeat alive but agent offline — keepalive fiber is running.
  // Show actual phase instead of misleading "offline".
  //
  // `keeper.phase` carries the typed `KeeperPhase` PascalCase token
  // (`dashboard/src/types/core.ts:879-892`), normalised by
  // `toKeeperPhase` at the wire boundary. Lowercasing it here is for
  // the display layer (`keeperDisplayStatus` callers expect lowercase
  // status labels like `'idle' / 'unbooted' / 'stopped'`).
  //
  // Only `'offline'` is filtered — that is the `'Offline'.toLowerCase()`
  // case we are refining away. The prior version also filtered
  // `'inactive'`, but `KeeperPhase` does not contain that variant
  // (audit: `keeper_state_machine.ml:21-34` `phase_to_string` emits
  // only the 13 PascalCase phases, none of which lowercase to
  // `'inactive'`), so the guard was dead defensive.
  if (keeper.last_heartbeat && isHeartbeatAlive(keeper.last_heartbeat)) {
    const phase = (keeper.lifecycle_phase ?? keeper.phase)?.trim().toLowerCase()
    if (phase && phase !== 'offline') return phase
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
  const detail = normalizeKeeperBlockerText(keeper.runtime_blocker_summary)
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
  admission_queue_wait_timeout: '대기열 진입 만료',
  turn_timeout_after_queue_wait: '대기 후 턴 만료',
  turn_timeout: '턴 응답 만료',
  turn_livelock_blocked: '턴 livelock 차단',
  completion_contract_violation: '완료 계약 위반',
  runtime_exhausted: '런타임 후보 소진',
  provider_runtime_error: '런타임 호출 오류',
  tool_route_recoverable_failure: '도구 라우팅 복구 가능 실패',
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
  no_progress_loop: 'No-progress 루프',
  sdk_max_turns_exceeded: 'SDK 최대 턴 초과',
  sdk_token_budget_exceeded: 'SDK 토큰 예산 초과',
  sdk_cost_budget_exceeded: 'SDK 비용 예산 초과',
  sdk_unrecognized_stop_reason: 'SDK 미식별 정지 사유',
  sdk_idle_detected: 'SDK Idle 감지',
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
  const runtimeBlocker = normalizeKeeperBlockerText(keeper.runtime_blocker_summary)
  if (runtimeBlocker && runtimeBlocker !== blockerClass) {
    return runtimeBlocker
  }
  if (blockerClass === 'ambiguous_post_commit_timeout') {
    return '최근 변경 이후 응답이 끊겨 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'ambiguous_post_commit_failure') {
    return '최근 변경 이후 실패가 있어 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'admission_queue_wait_timeout') {
    return 'Keeper admission FIFO 대기 시간이 초과되었습니다.'
  }
  if (blockerClass === 'turn_timeout_after_queue_wait') {
    return '대기 후 실행된 턴이 전체 제한 시간을 초과했습니다.'
  }
  if (blockerClass === 'turn_timeout') {
    return '턴 실행 시간이 제한 시간을 초과했습니다.'
  }
  if (blockerClass === 'completion_contract_violation') {
    return '완료 계약 조건을 만족하지 못해 재확인이 필요합니다.'
  }
  if (blockerClass === 'runtime_exhausted') {
    return '런타임 후보가 모두 소진되어 runtime 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'tool_route_recoverable_failure') {
    return '도구 라우팅이 복구 가능한 실패로 끝나 descriptor, tool surface, runtime lane 확인이 필요합니다.'
  }
  if (blockerClass === 'provider_runtime_error') {
    return '런타임 호출 경계가 keeper 진행 전에 실패했습니다.'
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
  if (blockerClass === 'no_progress_loop') {
    return NO_PROGRESS_LOOP_HINT
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
  // Use the SSOT predicate so a keeper paused by phase or pipeline_stage —
  // not just by the `paused` flag — still surfaces the "일시정지" prefix.
  // The same file already routes the *summary* and *short* axes through
  // isKeeperPaused (L135, L166); the runtime hint had drifted to raw flag.
  const paused = isKeeperPaused(keeper)
  const autoRecover = isKeeperAutoRecoverPause(keeper)
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  if (runtimeBlocker) {
    if (paused && autoRecover) return `자동 재시도 대기 · ${runtimeBlocker}`
    return paused ? `일시정지 원인 · ${runtimeBlocker}` : runtimeBlocker
  }
  const socialFallback = socialModelFallbackHint(keeper)
  if (socialFallback) return socialFallback
  const blocker = normalizeKeeperBlockerText(keeper.last_blocker)
  if (paused && autoRecover) return blocker ? `자동 재시도 대기 · ${blocker}` : '자동 재시도 대기'
  if (paused && blocker) return `일시정지 · ${blocker}`
  if (paused && keeper.keepalive_running) return '일시정지 · 하트비트만 유지 중'
  if (paused) return '일시정지됨'
  if (blocker) return `차단 요인 · ${blocker}`
  return null
}

/** One-line "what is this keeper doing" preview, shared by every keeper roster
 *  and summary surface so they agree on precedence.
 *
 *  Precedence: a real message output (recent_output/input_preview) first, then
 *  the most recent proactive turn's preview, then the goal / current-task
 *  fallbacks. The proactive preview matters because a proactive-only keeper
 *  never broadcasts — `recent_output_preview` is message-bus derived and stays
 *  empty for it — so its work surfaces solely through `last_proactive_preview`.
 *  Reading only the message fields left every proactive keeper rendering the
 *  bare "최근 작업 요약 없음" placeholder while the live signal sat unread on the
 *  same card (last_proactive_preview populated 13/15 in the fleet, all five
 *  message/goal fields 0/15). Returns null when no signal exists. */
export function keeperWorkPreview(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  return firstNonEmptyString(
    keeper.recent_output_preview,
    keeper.recent_input_preview,
    keeper.last_proactive_preview,
    keeper.goal,
    keeper.agent?.current_task,
  )
}
