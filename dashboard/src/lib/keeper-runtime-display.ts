import type { Keeper, KeeperRuntimeBlockerClass } from '../types'
import { relativeTime } from './format-time'
import { firstNonEmptyString } from './format-string'
import { isKeeperPaused } from './keeper-predicates'
// `fleet-tone` is leaf-level (it imports only `format-string`), so this
// direction introduces no cycle.
import { toKeeperPhaseToken, type KeeperPhaseToken } from './fleet-tone'
import { keeperHeartbeatStaleMs } from '../config/constants'

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
  /** Concrete subject of the activity when the server identified one —
   *  currently the tool name behind a tool_call / approval_pending signal.
   *  null when the activity has no finer identity (heartbeat, keeper_meta). */
  detail: string | null
  timestamp: string | null
  ageSeconds: number | null
}

interface KeeperActivityDisplayOptions {
  includeCreated?: boolean
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

type KeeperRuntimeDisplaySource = {
  runtime_id?: string | null
  runtime_canonical?: string | null
  selected_runtime_canonical?: string | null
}

type KeeperActivityDisplaySource = {
  last_heartbeat?: string | null
  tool_audit_at?: string | null
  last_activity_at?: string | null
  last_activity_source?: Keeper['last_activity_source'] | null
  last_activity_ago_s?: number | null
  last_turn_ago_s?: number | null
  created_at?: string | null
  live_activity?: Keeper['live_activity']
}

type ActivityCandidate = {
  source: KeeperActivitySource
  label: string
  detail: string | null
  timestamp: string | null
  ageSeconds: number
}

function trimmed(value: string | null | undefined): string | null {
  const text = value?.trim()
  return text ? text : null
}

export function normalizeKeeperBlockerText(value: string | null | undefined): string | null {
  return trimmed(value)
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

  return null
}

function timestampCandidate(
  source: KeeperActivitySource,
  label: string,
  timestamp: string | null | undefined,
  detail: string | null = null,
): ActivityCandidate | null {
  const value = trimmed(timestamp)
  if (!value) return null
  const ms = Date.parse(value)
  if (Number.isNaN(ms)) return null
  return {
    source,
    label,
    detail,
    timestamp: value,
    ageSeconds: Math.max(0, Math.round((Date.now() - ms) / 1000)),
  }
}

function ageCandidate(
  source: KeeperActivitySource,
  label: string,
  ageSeconds: number | null | undefined,
  detail: string | null = null,
): ActivityCandidate | null {
  if (typeof ageSeconds !== 'number' || !Number.isFinite(ageSeconds) || ageSeconds < 0) return null
  return {
    source,
    label,
    detail,
    timestamp: null,
    ageSeconds: Math.round(ageSeconds),
  }
}

/** Tool name behind the last-activity signal, when the server identified one.
 *  Only trusted when live_activity agrees with last_activity_source — the two
 *  fields are emitted together but can drift across partial refreshes. */
function liveActivityDetail(
  source: Keeper['last_activity_source'] | null | undefined,
  live: Keeper['live_activity'] | undefined,
): string | null {
  if (!live) return null
  const liveSource = live.source ?? null
  if (liveSource === null || liveSource !== (source ?? null)) return null
  switch (liveSource) {
    case 'tool_call':
    case 'approval_pending':
      return trimmed(live.tool)
    case 'keeper_meta':
      return null
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
  const activityDetail = liveActivityDetail(keeper?.last_activity_source, keeper?.live_activity)
  const candidates = [
    timestampCandidate(
      activityDisplaySource(keeper?.last_activity_source),
      activitySourceLabel(keeper?.last_activity_source),
      keeper?.last_activity_at,
      activityDetail,
    ),
    timestampCandidate('autonomous_action', '마지막 행동', keeper?.tool_audit_at),
    timestampCandidate('heartbeat', '하트비트', keeper?.last_heartbeat),
    // The ago_s fallback describes the same underlying activity as
    // last_activity_at — keep the source-derived label/detail instead of
    // collapsing to a generic '최근 활동'.
    ageCandidate(
      'last_activity',
      activitySourceLabel(keeper?.last_activity_source),
      keeper?.last_activity_ago_s,
      activityDetail,
    ),
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
    detail: null,
    timestamp: null,
    ageSeconds: null,
  }
}

/** The keeper status token every display surface keys on.
 *
 *  Returns `KeeperPhaseToken`, not `string`. Until 2026-07-27 this returned
 *  `string` and passed unmodelled values (`'idle'`, `'listening'`,
 *  `'handingoff'`, `'offline'`, and any unrecognized `keeper.status`)
 *  straight through; `phaseTokenFromKeeper` then collapsed them to
 *  `'unknown'`, which the roster and chat header render as `확인 필요`.
 *  Narrowing the return type moves that from a runtime collapse to a
 *  compile error at whichever arm produces a new value. */
export function keeperDisplayStatus(
  keeper: Keeper | null | undefined,
  fallbackStatus?: string | null,
): KeeperPhaseToken {
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

  return toKeeperPhaseToken(status) ?? 'unknown'
}

function keeperLifecycleStatus(
  phase: Keeper['lifecycle_phase'] | string | null | undefined,
): KeeperPhaseToken | null {
  switch (phase) {
    case 'Offline':
      return 'unbooted'
    case 'Running':
      return 'running'
    case 'Failing':
      return 'failing'
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
  if (blockerClass === 'provider_runtime_error') {
    return (
      transientProviderRuntimeText(keeper.runtime_blocker_summary)
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
 *  A recent heartbeat is authoritative for a live keeper; otherwise activity
 *  counters distinguish a cold start from a stopped process. */
function refineOfflineStatus(keeper: Keeper | null | undefined): KeeperPhaseToken {
  if (!keeper) return 'offline'

  // Heartbeat alive — keepalive fiber is running. Show actual phase instead of
  // misleading "offline".
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
  if (keeper.last_heartbeat && isHeartbeatAlive(keeper, keeper.last_heartbeat)) {
    // Route through `keeperLifecycleStatus`, not an open-ended lowercase
    // conversion, so only the closed KeeperPhase vocabulary reaches the
    // display token layer. Unrecognized phases still fall through to `idle`.
    const phase = (keeper.lifecycle_phase ?? keeper.phase)?.trim()
    if (phase && phase.toLowerCase() !== 'offline') {
      return keeperLifecycleStatus(phase) ?? toKeeperPhaseToken(phase) ?? 'idle'
    }
    return 'idle'
  }

  const turnCount = keeper.turn_count ?? 0

  // Never ran a single turn — never booted
  if (turnCount === 0) {
    return 'unbooted'
  }

  // Had activity before but now offline — stopped/crashed
  if (turnCount > 0) {
    return 'stopped'
  }

  return 'offline'
}

function isHeartbeatAlive(keeper: Keeper, heartbeat: string): boolean {
  const ts = new Date(heartbeat).getTime()
  if (Number.isNaN(ts)) return false
  return Date.now() - ts < keeperHeartbeatStaleMs(keeper.heartbeat_stale_after_s)
}

const runtimeBlockerLabels = {
  runtime_exhausted: '런타임 후보 소진',
  provider_runtime_error: '런타임 호출 오류',
  fiber_unresolved: 'Fiber 미해결',
  stale_termination_storm: 'Stale 종료 폭주',
  heartbeat_failures: '하트비트 실패',
  turn_failures: '턴 실패 반복',
  exception: '런타임 예외',
  agent_core_context_window_exceeded: 'Agent Core 컨텍스트 윈도 초과',
  agent_core_unrecognized_stop_reason: 'Agent Core 미식별 정지 사유',
  agent_core_guardrail_violation: 'Agent Core 가드레일 위반',
  agent_core_tripwire_violation: 'Agent Core Tripwire 위반',
  agent_core_input_required: 'Agent Core 입력 대기',
  capacity_backpressure: '공급자 용량 초과',
  gate_replay_repair_required: '승인 기록 복구 필요',
  incomplete_tool_transcript: '도구 기록 깨짐',
  internal_bridge_exception: '브리지 예외',
  internal_contract_rejected: '내부 계약 거절',
  internal_unhandled_exception: '처리하지 못한 예외',
  provider_attempt_effect_fenced: '중복 실행 위험으로 차단',
  receipt_persistence_failed: 'Receipt 저장 실패',
  terminal_effect_failed: '마무리 처리 실패',
  tool_correction_lost: '도구 수정 내용 유실',
} satisfies Record<KeeperRuntimeBlockerClass, string>

export function keeperRuntimeBlockerLabel(
  blockerClass: Keeper['runtime_blocker_class'] | null | undefined,
): string | null {
  if (!blockerClass) return null
  return runtimeBlockerLabels[blockerClass] ?? null
}

export function keeperRuntimeBlockerHint(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  const blockerClass = keeper.runtime_blocker_class
  const runtimeBlocker = normalizeKeeperBlockerText(keeper.runtime_blocker_summary)
  if (runtimeBlocker && runtimeBlocker !== blockerClass) {
    return runtimeBlocker
  }
  if (blockerClass === 'runtime_exhausted') {
    return '런타임 후보가 모두 소진되어 runtime 상태 확인이 필요합니다.'
  }
  if (blockerClass === 'provider_runtime_error') {
    return '런타임 호출 경계가 keeper 진행 전에 실패했습니다.'
  }
  if (blockerClass === 'fiber_unresolved') {
    return 'Keeper fiber가 종료 상태를 확정하지 못해 supervisor 확인이 필요합니다.'
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
  if (keeper?.tool_audit_at) {
    return `마지막 행동 · ${relativeTime(keeper.tool_audit_at)}`
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
  if (paused && autoRecover) return '자동 재시도 대기'
  if (paused && keeper.keepalive_running) return '일시정지 · 하트비트만 유지 중'
  if (paused) return '일시정지됨'
  return null
}

/** One-line "what is this keeper doing" preview, shared by every keeper roster
 *  and summary surface so they agree on precedence.
 *
 *  Precedence: a real message output (recent_output/input_preview) first, then
 *  the most recent proactive turn's preview, then the current-task
 *  fallbacks. The proactive preview matters because a proactive-only keeper
 *  never broadcasts — `recent_output_preview` is message-bus derived and stays
 *  empty for it — so its work surfaces solely through `last_proactive_preview`.
 *  Reading only the message fields left every proactive keeper rendering the
 *  bare "최근 작업 요약 없음" placeholder while the live signal sat unread on the
 *  same card. Returns null when no signal exists. */
export function keeperWorkPreview(keeper: Keeper | null | undefined): string | null {
  if (!keeper) return null
  return firstNonEmptyString(
    keeper.recent_output_preview,
    keeper.recent_input_preview,
    keeper.last_proactive_preview,
  )
}
