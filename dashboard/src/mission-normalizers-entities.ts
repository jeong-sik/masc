import { isRecord, asString, asNumber, asStringArray } from './components/common/normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import type {
  DashboardMissionAttentionQueueItem,
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
    related_agent_names: asStringArray(raw.related_agent_names),
    evidence: raw.evidence,
    evidence_preview: asStringArray(raw.evidence_preview),
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
    current_work: asString(raw.current_work) ?? null,
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
    recent_tool_names: asStringArray(raw.recent_tool_names),
  }
}

export function normalizeKeeperBrief(raw: unknown): DashboardMissionKeeperBrief | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    status: asString(raw.status),
    context_ratio: asNumber(raw.context_ratio) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s) ?? null,
    current_work: asString(raw.current_work) ?? null,
    latest_tool_names: asStringArray(raw.latest_tool_names),
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
