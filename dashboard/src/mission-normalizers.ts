import { isRecord, asString, asNumber, asBoolean, extractArray, asStringArray } from './components/common/normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import { normalizeKeeperTrust } from './keeper-store-normalize'
import { normalizeOperatorActionDescriptor } from './pending-confirm'
import {
  normalizeAgentBrief,
  normalizeAttentionQueueItem,
  normalizeInternalSignal,
  normalizeKeeperBrief,
} from './mission-normalizers-entities'
import type {
  DashboardMissionAgentBrief,
  DashboardMissionAttentionQueueItem,
  DashboardMissionBriefingResponse,
  DashboardMissionBriefingSection,
  DashboardMissionBriefingMetadataGap,
  DashboardMissionInternalSignal,
  DashboardMissionKeeperBrief,
  DashboardMissionResponse,
  DashboardMissionSummary,
  DashboardMissionCommandFocus,
  DashboardMissionTargets,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorKeeperSnapshot,
  OperatorRecommendedAction,
} from './types'

function normalizeKeeper(raw: unknown): OperatorKeeperSnapshot | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    phase: asString(raw.phase) ?? null,
    pipeline_stage: asString(raw.pipeline_stage) ?? null,
    paused: asBoolean(raw.paused) ?? null,
    // The brief row publishes health as a top-level word; the execution
    // route publishes the same axis under `diagnostic.health_state`. Two
    // placements, one axis — `isKeeperOffline` parses either.
    health: asString(raw.health) ?? null,
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    context_ratio: asNumber(raw.context_ratio),
    generation: asNumber(raw.generation),
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: asString(raw.model),
    needs_attention: typeof raw.needs_attention === 'boolean' ? raw.needs_attention : null,
    attention_reason: asString(raw.attention_reason) ?? null,
    next_human_action: asString(raw.next_human_action) ?? null,
    runtime_trust: normalizeKeeperTrust(raw.runtime_trust ?? raw.trust),
  }
}

// normalizePendingConfirmation imported from pending-confirm.ts (SSOT)

function normalizeSummary(raw: unknown): DashboardMissionSummary {
  const root = isRecord(raw) ? raw : {}
  return {
    workspace_health: asString(root.workspace_health),
    cluster: asString(root.cluster),
    project: asString(root.project),
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
  return {
    health: asString(root.health),
    active_operations: asNumber(root.active_operations),
    pending_approvals: asNumber(root.pending_approvals),
    top_attention: normalizeAttentionItem(root.top_attention),
    top_action: normalizeRecommendedAction(root.top_action),
  }
}

function normalizeTargets(raw: unknown): DashboardMissionTargets {
  const root = isRecord(raw) ? raw : {}
  return {
    keepers: extractArray(root.keepers, ['items'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    available_actions: extractArray(root.available_actions)
      .map(normalizeOperatorActionDescriptor)
      .filter((item): item is OperatorActionDescriptor => item !== null),
  }
}

export function normalizeMission(raw: unknown): DashboardMissionResponse {
  const root = isRecord(raw) ? raw : {}
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
    evidence: asStringArray(raw.evidence),
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

export function normalizeMissionBriefing(raw: unknown): DashboardMissionBriefingResponse {
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
    criteria: asStringArray(root.criteria),
    basis: {
      namespace: asString(basis.namespace) ?? null,
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
