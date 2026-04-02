import { isRecord, asString, asNumber, extractArray } from './components/common/normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import type {
  DashboardMissionAttentionQueueItem,
  DashboardMissionKeeperRef,
  DashboardMissionOperationBadge,
  DashboardMissionParticipantPreview,
  DashboardMissionSessionCard,
  DashboardMissionSessionBrief,
  DashboardMissionTimelineItem,
  DashboardMissionAgentBrief,
  DashboardMissionInternalSignal,
  DashboardMissionKeeperBrief,
} from './types'

export function normalizeAttentionQueueItem(raw: unknown): DashboardMissionAttentionQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!id || !kind || !summary || !targetType) return null
  return {
    id,
    kind,
    severity: asString(raw.severity) ?? 'unknown',
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

export function normalizeSessionBrief(raw: unknown): DashboardMissionSessionBrief | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  const goal = asString(raw.goal)
  if (!sessionId || !goal) return null
  return {
    session_id: sessionId,
    goal,
    created_by: asString(raw.created_by) ?? null,
    origin_kind: asString(raw.origin_kind) === 'system' ? 'system' : 'human',
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

export function normalizeParticipantPreview(raw: unknown): DashboardMissionParticipantPreview | null {
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

export function normalizeOperationBadge(raw: unknown): DashboardMissionOperationBadge | null {
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

export function normalizeKeeperRef(raw: unknown): DashboardMissionKeeperRef | null {
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

export function normalizeMissionSessionCard(raw: unknown): DashboardMissionSessionCard | null {
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

export function normalizeAgentBrief(raw: unknown): DashboardMissionAgentBrief | null {
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

export function normalizeKeeperBrief(raw: unknown): DashboardMissionKeeperBrief | null {
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
    latest_tool_names: extractArray(raw.latest_tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    latest_tool_call_count: asNumber(raw.latest_tool_call_count) ?? null,
    tool_audit_source: asString(raw.tool_audit_source) ?? null,
    tool_audit_at: asString(raw.tool_audit_at) ?? null,
  }
}

export function normalizeInternalSignal(raw: unknown): DashboardMissionInternalSignal | null {
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
    severity: asString(raw.severity) ?? 'unknown',
    summary,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    attention: normalizeAttentionItem(raw.attention),
    action: normalizeRecommendedAction(raw.action),
  }
}

export function normalizeTimelineItem(raw: unknown): DashboardMissionTimelineItem | null {
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
