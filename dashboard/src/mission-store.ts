import { signal } from '@preact/signals'
import {
  fetchDashboardMission,
  fetchDashboardMissionBriefing,
  fetchDashboardMissionSession,
} from './api'
import { isRecord, asString, asNumber, asBoolean, extractArray } from './components/common/normalize'
import type {
  DashboardMissionAgentBrief,
  DashboardMissionAttentionQueueItem,
  DashboardMissionBriefingResponse,
  DashboardMissionBriefingSection,
  DashboardMissionBriefingMetadataGap,
  DashboardMissionInternalSignal,
  DashboardMissionKeeperBrief,
  DashboardMissionKeeperRef,
  DashboardMissionOperationBadge,
  DashboardMissionParticipantPreview,
  DashboardMissionResponse,
  DashboardMissionSessionCard,
  DashboardMissionSessionDetailResponse,
  DashboardMissionSessionBrief,
  DashboardMissionSummary,
  DashboardMissionTimelineItem,
  DashboardMissionCommandFocus,
  DashboardMissionTargets,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorKeeperSnapshot,
  OperatorRecommendedAction,
  OperatorSessionCard,
  OperatorSessionSnapshot,
  PendingConfirmation,
} from './types'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'

export const missionSnapshot = signal<DashboardMissionResponse | null>(null)
export const missionLoading = signal(false)
export const missionError = signal<string | null>(null)
export const missionBriefing = signal<DashboardMissionBriefingResponse | null>(null)
export const missionBriefingLoading = signal(false)
export const missionBriefingError = signal<string | null>(null)
export const missionSessionDetail = signal<DashboardMissionSessionDetailResponse | null>(null)
export const missionSessionDetailLoading = signal(false)
export const missionSessionDetailError = signal<string | null>(null)

let missionBriefingPollTimer: number | null = null

function clearMissionBriefingPoll(): void {
  if (missionBriefingPollTimer !== null) {
    window.clearTimeout(missionBriefingPollTimer)
    missionBriefingPollTimer = null
  }
}

function scheduleMissionBriefingPoll(delayMs = 1500): void {
  if (missionBriefingPollTimer !== null) return
  missionBriefingPollTimer = window.setTimeout(() => {
    missionBriefingPollTimer = null
    void refreshMissionBriefing(false)
  }, delayMs)
}


function normalizeSessionCard(raw: unknown): OperatorSessionCard | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  if (!sessionId) return null
  return {
    session_id: sessionId,
    goal: asString(raw.goal),
    status: asString(raw.status),
    health: asString(raw.health),
    scale_profile: asString(raw.scale_profile),
    control_profile: asString(raw.control_profile),
    planned_worker_count: asNumber(raw.planned_worker_count),
    active_agent_count: asNumber(raw.active_agent_count),
    last_turn_age_sec: asNumber(raw.last_turn_age_sec) ?? null,
    attention_count: asNumber(raw.attention_count),
    recommended_action_count: asNumber(raw.recommended_action_count),
    top_attention: normalizeAttentionItem(raw.top_attention),
    top_recommendation: normalizeRecommendedAction(raw.top_recommendation),
  }
}

function normalizeSession(raw: unknown): OperatorSessionSnapshot | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  if (!sessionId) return null
  const payload = isRecord(raw.status) ? raw.status : raw
  const payloadSummary = isRecord(payload.summary) ? payload.summary : undefined
  return {
    session_id: sessionId,
    status:
      asString(raw.status)
      ?? asString(payloadSummary?.status)
      ?? (isRecord(payload.session) ? asString(payload.session.status) : undefined),
    progress_pct: asNumber(raw.progress_pct) ?? asNumber(payloadSummary?.progress_pct),
    elapsed_sec: asNumber(raw.elapsed_sec) ?? asNumber(payloadSummary?.elapsed_sec),
    remaining_sec: asNumber(raw.remaining_sec) ?? asNumber(payloadSummary?.remaining_sec),
    done_delta_total: asNumber(raw.done_delta_total) ?? asNumber(payloadSummary?.done_delta_total),
    summary: isRecord(raw.summary) ? raw.summary : payloadSummary,
    team_health:
      isRecord(raw.team_health)
        ? raw.team_health
        : (isRecord(payload.team_health) ? payload.team_health : undefined),
    communication_metrics:
      isRecord(raw.communication_metrics)
        ? raw.communication_metrics
        : (isRecord(payload.communication_metrics) ? payload.communication_metrics : undefined),
    orchestration_state:
      isRecord(raw.orchestration_state)
        ? raw.orchestration_state
        : (isRecord(payload.orchestration_state) ? payload.orchestration_state : undefined),
    cascade_metrics:
      isRecord(raw.cascade_metrics)
        ? raw.cascade_metrics
        : (isRecord(payload.cascade_metrics) ? payload.cascade_metrics : undefined),
    report_paths: isRecord(raw.report_paths)
      ? Object.fromEntries(
          Object.entries(raw.report_paths)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : (isRecord(payload.report_paths)
          ? Object.fromEntries(
              Object.entries(payload.report_paths)
                .map(([key, value]) => {
                  const text = asString(value)
                  return text ? [key, text] : null
                })
                .filter((entry): entry is [string, string] => entry !== null),
            )
          : undefined),
    session: isRecord(raw.session) ? raw.session : (isRecord(payload.session) ? payload.session : undefined),
    recent_events: extractArray(raw.recent_events, ['events']).filter(isRecord),
  }
}

function normalizeKeeper(raw: unknown): OperatorKeeperSnapshot | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    autonomy_level: asString(raw.autonomy_level),
    context_ratio: asNumber(raw.context_ratio),
    generation: asNumber(raw.generation),
    active_goal_ids: extractArray(raw.active_goal_ids)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: asString(raw.model),
  }
}

function normalizePendingConfirmation(raw: unknown): PendingConfirmation | null {
  if (!isRecord(raw)) return null
  const token = asString(raw.confirm_token) ?? asString(raw.token)
  if (!token) return null
  return {
    confirm_token: token,
    actor: asString(raw.actor),
    action_type: asString(raw.action_type),
    target_type: asString(raw.target_type),
    target_id: asString(raw.target_id) ?? null,
    delegated_tool: asString(raw.delegated_tool),
    created_at: asString(raw.created_at),
    preview: raw.preview,
  }
}

function normalizeActionDescriptor(raw: unknown): OperatorActionDescriptor | null {
  if (!isRecord(raw)) return null
  const actionType = asString(raw.action_type)
  const targetType = asString(raw.target_type)
  if (!actionType || !targetType) return null
  return {
    action_type: actionType,
    target_type: targetType,
    description: asString(raw.description),
    confirm_required: asBoolean(raw.confirm_required),
  }
}

function normalizeSummary(raw: unknown): DashboardMissionSummary {
  const root = isRecord(raw) ? raw : {}
  return {
    room_health: asString(root.room_health),
    cluster: asString(root.cluster),
    project: asString(root.project),
    current_room: asString(root.current_room) ?? asString(root.room) ?? null,
    paused: asBoolean(root.paused),
    tempo_interval_s: asNumber(root.tempo_interval_s),
    active_agents: asNumber(root.active_agents),
    keeper_pressure: asNumber(root.keeper_pressure),
    active_operations: asNumber(root.active_operations),
    pending_approvals: asNumber(root.pending_approvals),
    incident_count: asNumber(root.incident_count),
    recommended_action_count: asNumber(root.recommended_action_count),
    top_attention: normalizeAttentionItem(root.top_attention),
    top_action: normalizeRecommendedAction(root.top_action),
  }
}

function normalizeCommandFocus(raw: unknown): DashboardMissionCommandFocus {
  const root = isRecord(raw) ? raw : {}
  const swarm = isRecord(root.swarm_overview) ? root.swarm_overview : {}
  return {
    health: asString(root.health),
    active_operations: asNumber(root.active_operations),
    pending_approvals: asNumber(root.pending_approvals),
    swarm_overview: {
      active_lanes: asNumber(swarm.active_lanes),
      moving_lanes: asNumber(swarm.moving_lanes),
      stalled_lanes: asNumber(swarm.stalled_lanes),
      projected_lanes: asNumber(swarm.projected_lanes),
      last_movement_at: asString(swarm.last_movement_at) ?? null,
    },
    top_attention: normalizeAttentionItem(root.top_attention),
    top_action: normalizeRecommendedAction(root.top_action),
    session_cards: extractArray(root.session_cards)
      .map(normalizeSessionCard)
      .filter((item): item is OperatorSessionCard => item !== null),
  }
}

function normalizeTargets(raw: unknown): DashboardMissionTargets {
  const root = isRecord(raw) ? raw : {}
  return {
    sessions: extractArray(root.sessions, ['items'])
      .map(normalizeSession)
      .filter((item): item is OperatorSessionSnapshot => item !== null),
    keepers: extractArray(root.keepers, ['items'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    pending_confirms: extractArray(root.pending_confirms)
      .map(normalizePendingConfirmation)
      .filter((item): item is PendingConfirmation => item !== null),
    available_actions: extractArray(root.available_actions)
      .map(normalizeActionDescriptor)
      .filter((item): item is OperatorActionDescriptor => item !== null),
  }
}

function normalizeAttentionQueueItem(raw: unknown): DashboardMissionAttentionQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!id || !kind || !summary || !targetType) return null
  return {
    id,
    kind,
    severity: asString(raw.severity) ?? 'warn',
    summary,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    top_action: normalizeRecommendedAction(raw.top_action),
    related_session_ids: extractArray(raw.related_session_ids)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    related_agent_names: extractArray(raw.related_agent_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    evidence_preview: extractArray(raw.evidence_preview)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    last_seen_at: asString(raw.last_seen_at) ?? null,
  }
}

function normalizeSessionBrief(raw: unknown): DashboardMissionSessionBrief | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  const goal = asString(raw.goal)
  if (!sessionId || !goal) return null
  return {
    session_id: sessionId,
    goal,
    room: asString(raw.room) ?? null,
    status: asString(raw.status),
    health: asString(raw.health),
    member_names: extractArray(raw.member_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    started_at: asString(raw.started_at) ?? null,
    elapsed_sec: asNumber(raw.elapsed_sec) ?? null,
    operation_id: asString(raw.operation_id) ?? null,
    blocker_summary: asString(raw.blocker_summary) ?? null,
    last_event_at: asString(raw.last_event_at) ?? null,
    last_event_summary: asString(raw.last_event_summary) ?? null,
    communication_summary: asString(raw.communication_summary) ?? null,
    active_count: asNumber(raw.active_count),
    seen_count: asNumber(raw.seen_count),
    planned_count: asNumber(raw.planned_count),
    required_count: asNumber(raw.required_count),
    counts_basis: asString(raw.counts_basis) ?? null,
    related_attention_count: asNumber(raw.related_attention_count) ?? 0,
    top_attention: normalizeAttentionItem(raw.top_attention),
    top_recommendation: normalizeRecommendedAction(raw.top_recommendation),
  }
}

function normalizeParticipantPreview(raw: unknown): DashboardMissionParticipantPreview | null {
  if (!isRecord(raw)) return null
  const agentName = asString(raw.agent_name)
  if (!agentName) return null
  return {
    agent_name: agentName,
    display_name: asString(raw.display_name) ?? null,
    is_live: typeof raw.is_live === 'boolean' ? raw.is_live : undefined,
    current_work: asString(raw.current_work) ?? null,
    recent_input_preview: asString(raw.recent_input_preview) ?? null,
    recent_output_preview: asString(raw.recent_output_preview) ?? null,
    recent_tool_names: extractArray(raw.recent_tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    last_activity_at: asString(raw.last_activity_at) ?? null,
  }
}

function normalizeOperationBadge(raw: unknown): DashboardMissionOperationBadge | null {
  if (!isRecord(raw)) return null
  const operationId = asString(raw.operation_id)
  if (!operationId) return null
  return {
    operation_id: operationId,
    status: asString(raw.status),
    stage: asString(raw.stage) ?? null,
    detachment_status: asString(raw.detachment_status) ?? null,
    objective: asString(raw.objective) ?? null,
    updated_at: asString(raw.updated_at) ?? null,
  }
}

function normalizeKeeperRef(raw: unknown): DashboardMissionKeeperRef | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    agent_name: asString(raw.agent_name) ?? null,
    status: asString(raw.status),
    generation: asNumber(raw.generation),
    context_ratio: asNumber(raw.context_ratio) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s) ?? null,
    current_work: asString(raw.current_work) ?? null,
  }
}

function normalizeMissionSessionCard(raw: unknown): DashboardMissionSessionCard | null {
  const base = normalizeSessionBrief(raw)
  if (!base) return null
  return {
    ...base,
    member_previews: extractArray(isRecord(raw) ? raw.member_previews : undefined)
      .map(normalizeParticipantPreview)
      .filter((item): item is DashboardMissionParticipantPreview => item !== null),
    operation_badges: extractArray(isRecord(raw) ? raw.operation_badges : undefined)
      .map(normalizeOperationBadge)
      .filter((item): item is DashboardMissionOperationBadge => item !== null),
    keeper_refs: extractArray(isRecord(raw) ? raw.keeper_refs : undefined)
      .map(normalizeKeeperRef)
      .filter((item): item is DashboardMissionKeeperRef => item !== null),
  }
}

function normalizeAgentBrief(raw: unknown): DashboardMissionAgentBrief | null {
  if (!isRecord(raw)) return null
  const agentName = asString(raw.agent_name)
  if (!agentName) return null
  return {
    agent_name: agentName,
    display_name: asString(raw.display_name) ?? null,
    is_live: typeof raw.is_live === 'boolean' ? raw.is_live : undefined,
    archived_reason: asString(raw.archived_reason) ?? null,
    status: asString(raw.status),
    where: asString(raw.where) ?? null,
    with_whom: extractArray(raw.with_whom)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    current_work: asString(raw.current_work) ?? null,
    related_session_id: asString(raw.related_session_id) ?? null,
    related_attention_count: asNumber(raw.related_attention_count) ?? 0,
    last_activity_at: asString(raw.last_activity_at) ?? null,
    last_activity_age_sec: asNumber(raw.last_activity_age_sec) ?? null,
    signal_truth:
      asString(raw.signal_truth) === 'live'
      || asString(raw.signal_truth) === 'stale'
      || asString(raw.signal_truth) === 'archived'
      || asString(raw.signal_truth) === 'unknown'
        ? (asString(raw.signal_truth) as DashboardMissionAgentBrief['signal_truth'])
        : undefined,
    evidence_source:
      asString(raw.evidence_source) === 'message'
      || asString(raw.evidence_source) === 'presence'
      || asString(raw.evidence_source) === 'session'
      || asString(raw.evidence_source) === 'none'
        ? (asString(raw.evidence_source) as DashboardMissionAgentBrief['evidence_source'])
        : undefined,
    recent_output_preview: asString(raw.recent_output_preview) ?? null,
    recent_input_preview: asString(raw.recent_input_preview) ?? null,
    recent_tool_names: extractArray(raw.recent_tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
  }
}

function normalizeKeeperBrief(raw: unknown): DashboardMissionKeeperBrief | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    agent_name: asString(raw.agent_name) ?? null,
    status: asString(raw.status),
    generation: asNumber(raw.generation),
    context_ratio: asNumber(raw.context_ratio) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s) ?? null,
    current_work: asString(raw.current_work) ?? null,
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    allowed_tool_names: extractArray(raw.allowed_tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    latest_tool_names: extractArray(raw.latest_tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    latest_tool_call_count: asNumber(raw.latest_tool_call_count) ?? null,
    tool_audit_source: asString(raw.tool_audit_source) ?? null,
    tool_audit_at: asString(raw.tool_audit_at) ?? null,
  }
}

function normalizeInternalSignal(raw: unknown): DashboardMissionInternalSignal | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const signalType = asString(raw.signal_type)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!id || !signalType || !summary || !targetType) return null
  const normalizedType = signalType === 'action' ? 'action' : 'attention'
  return {
    id,
    signal_type: normalizedType,
    severity: asString(raw.severity) ?? 'warn',
    summary,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    attention: normalizeAttentionItem(raw.attention),
    action: normalizeRecommendedAction(raw.action),
  }
}

function normalizeMission(raw: unknown): DashboardMissionResponse {
  const root = isRecord(raw) ? raw : {}
  const sessionBriefs = extractArray(root.session_briefs)
    .map(normalizeSessionBrief)
    .filter((item): item is DashboardMissionSessionBrief => item !== null)
  const sessionCards =
    extractArray(root.sessions)
      .map(normalizeMissionSessionCard)
      .filter((item): item is DashboardMissionSessionCard => item !== null)
  return {
    generated_at: asString(root.generated_at),
    summary: normalizeSummary(root.summary),
    incidents: extractArray(root.incidents)
      .map(normalizeAttentionItem)
      .filter((item): item is OperatorAttentionItem => item !== null),
    recommended_actions: extractArray(root.recommended_actions)
      .map(normalizeRecommendedAction)
      .filter((item): item is OperatorRecommendedAction => item !== null),
    command_focus: normalizeCommandFocus(root.command_focus),
    operator_targets: normalizeTargets(root.operator_targets),
    attention_queue: extractArray(root.attention_queue)
      .map(normalizeAttentionQueueItem)
      .filter((item): item is DashboardMissionAttentionQueueItem => item !== null),
    sessions: sessionCards.length > 0
      ? sessionCards
      : sessionBriefs.map(item => ({ ...item, member_previews: [], operation_badges: [], keeper_refs: [] })),
    session_briefs: sessionBriefs,
    agent_briefs: extractArray(root.agent_briefs)
      .map(normalizeAgentBrief)
      .filter((item): item is DashboardMissionAgentBrief => item !== null),
    keeper_briefs: extractArray(root.keeper_briefs)
      .map(normalizeKeeperBrief)
      .filter((item): item is DashboardMissionKeeperBrief => item !== null),
    internal_signals: extractArray(root.internal_signals)
      .map(normalizeInternalSignal)
      .filter((item): item is DashboardMissionInternalSignal => item !== null),
  }
}

function normalizeTimelineItem(raw: unknown): DashboardMissionTimelineItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const summary = asString(raw.summary)
  if (!id || !summary) return null
  return {
    id,
    timestamp: asString(raw.timestamp) ?? null,
    event_type: asString(raw.event_type),
    actor: asString(raw.actor) ?? null,
    summary,
  }
}

function normalizeMissionSessionDetail(raw: unknown): DashboardMissionSessionDetailResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    generated_at: asString(root.generated_at),
    session_id: asString(root.session_id) ?? '',
    session: normalizeMissionSessionCard(root.session),
    timeline: extractArray(root.timeline)
      .map(normalizeTimelineItem)
      .filter((item): item is DashboardMissionTimelineItem => item !== null),
    participants: extractArray(root.participants)
      .map(normalizeParticipantPreview)
      .filter((item): item is DashboardMissionParticipantPreview => item !== null),
    operations: extractArray(root.operations)
      .map(normalizeOperationBadge)
      .filter((item): item is DashboardMissionOperationBadge => item !== null),
    keepers: extractArray(root.keepers)
      .map(normalizeKeeperRef)
      .filter((item): item is DashboardMissionKeeperRef => item !== null),
    error: asString(root.error) ?? null,
  }
}

function normalizeBriefingSection(raw: unknown): DashboardMissionBriefingSection | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const label = asString(raw.label)
  const summary = asString(raw.summary)
  if (!id || !label || !summary) return null
  const statusRaw = asString(raw.status) ?? 'unclear'
  const status =
    statusRaw === 'ok'
    || statusRaw === 'healthy'
    || statusRaw === 'aligned'
    || statusRaw === 'watch'
    || statusRaw === 'risk'
    || statusRaw === 'unclear'
      ? statusRaw
      : 'unclear'
  return {
    id,
    label,
    status,
    summary,
    signal_class:
      asString(raw.signal_class) === 'metadata_gap'
      || asString(raw.signal_class) === 'mixed'
      || asString(raw.signal_class) === 'operational_risk'
        ? (asString(raw.signal_class) as DashboardMissionBriefingSection['signal_class'])
        : undefined,
    evidence_quality:
      asString(raw.evidence_quality) === 'strong'
      || asString(raw.evidence_quality) === 'partial'
      || asString(raw.evidence_quality) === 'missing'
        ? (asString(raw.evidence_quality) as DashboardMissionBriefingSection['evidence_quality'])
        : undefined,
    evidence: extractArray(raw.evidence)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
  }
}

function normalizeMetadataGap(raw: unknown): DashboardMissionBriefingMetadataGap | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const scopeType = asString(raw.scope_type)
  const severity = asString(raw.severity)
  if (!kind || !summary || !scopeType || !severity) return null
  if (scopeType !== 'session' && scopeType !== 'keeper' && scopeType !== 'agent') return null
  if (severity !== 'info' && severity !== 'watch') return null
  return {
    kind,
    summary,
    scope_type: scopeType,
    scope_id: asString(raw.scope_id) ?? null,
    severity,
  }
}

function normalizeMissionBriefing(raw: unknown): DashboardMissionBriefingResponse {
  const root = isRecord(raw) ? raw : {}
  const basis = isRecord(root.basis) ? root.basis : {}
  const statusRaw = asString(root.status) ?? 'error'
  const status =
    statusRaw === 'ok'
      || statusRaw === 'pending'
      || statusRaw === 'unavailable'
      || statusRaw === 'error'
      ? statusRaw
      : 'error'
  return {
    generated_at: asString(root.generated_at),
    cached: asBoolean(root.cached),
    stale: asBoolean(root.stale),
    refreshing: asBoolean(root.refreshing),
    status,
    summary: asString(root.summary) ?? null,
    model: asString(root.model) ?? null,
    ttl_sec: asNumber(root.ttl_sec),
    criteria: extractArray(root.criteria)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    basis: {
      current_room: asString(basis.current_room) ?? null,
      crew_count: asNumber(basis.crew_count),
      agent_count: asNumber(basis.agent_count),
      keeper_count: asNumber(basis.keeper_count),
    },
    metadata_gap_count: asNumber(root.metadata_gap_count),
    metadata_gaps: extractArray(root.metadata_gaps)
      .map(normalizeMetadataGap)
      .filter((item): item is DashboardMissionBriefingMetadataGap => item !== null),
    sections: extractArray(root.sections)
      .map(normalizeBriefingSection)
      .filter((item): item is DashboardMissionBriefingSection => item !== null),
    error: asString(root.error) ?? null,
    last_error: asString(root.last_error) ?? null,
  }
}

export async function refreshMissionSnapshot(mode?: 'snapshot' | 'full'): Promise<void> {
  missionLoading.value = true
  missionError.value = null
  try {
    const raw = await fetchDashboardMission(mode)
    missionSnapshot.value = normalizeMission(raw)
  } catch (err) {
    missionError.value = err instanceof Error ? err.message : 'Failed to load mission snapshot'
  } finally {
    missionLoading.value = false
  }
}

export async function refreshMissionSessionDetail(sessionId: string | null | undefined): Promise<void> {
  if (!sessionId) {
    missionSessionDetail.value = null
    missionSessionDetailError.value = null
    missionSessionDetailLoading.value = false
    return
  }
  missionSessionDetailLoading.value = true
  missionSessionDetailError.value = null
  try {
    const raw = await fetchDashboardMissionSession(sessionId)
    missionSessionDetail.value = normalizeMissionSessionDetail(raw)
  } catch (err) {
    missionSessionDetailError.value = err instanceof Error ? err.message : 'Failed to load session detail'
  } finally {
    missionSessionDetailLoading.value = false
  }
}

export async function refreshMissionBriefing(force = false): Promise<void> {
  missionBriefingLoading.value = true
  missionBriefingError.value = null
  try {
    const raw = await fetchDashboardMissionBriefing(force)
    const normalized = normalizeMissionBriefing(raw)
    missionBriefing.value = normalized
    if (normalized.refreshing || normalized.status === 'pending') {
      scheduleMissionBriefingPoll()
    } else {
      clearMissionBriefingPoll()
    }
  } catch (err) {
    missionBriefingError.value = err instanceof Error ? err.message : 'Failed to load mission briefing'
    clearMissionBriefingPoll()
  } finally {
    missionBriefingLoading.value = false
  }
}
