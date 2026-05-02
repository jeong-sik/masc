import { isRecord, asString, asNumber, asBoolean, extractArray } from './components/common/normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import { normalizeKeeperTrust } from './keeper-store-normalize'
import {
  normalizeAgentBrief,
  normalizeAttentionQueueItem,
  normalizeInternalSignal,
  normalizeKeeperBrief,
  normalizeKeeperRef,
  normalizeMissionSessionCard,
  normalizeOperationBadge,
  normalizeParticipantPreview,
  normalizeTimelineItem,
} from './mission-normalizers-entities'
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
  DashboardMissionSessionWorkerRuns,
  DashboardMissionSummary,
  DashboardMissionTimelineItem,
  DashboardMissionWorkerReadiness,
  DashboardMissionCommandFocus,
  DashboardProofWorkerRunEvidence,
  DashboardMissionTargets,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorKeeperSnapshot,
  OperatorRecommendedAction,
  PendingConfirmation,
} from './types'

function normalizeWorkerRunEvidence(raw: unknown): DashboardProofWorkerRunEvidence | null {
  if (!isRecord(raw)) return null
  const workerRunId = asString(raw.worker_run_id)
  if (!workerRunId) return null
  return {
    worker_run_id: workerRunId,
    session_id: asString(raw.session_id) ?? null,
    operation_id: asString(raw.operation_id) ?? null,
    trace_ref: isRecord(raw.trace_ref) ? raw.trace_ref : null,
    evidence_session_id: asString(raw.evidence_session_id) ?? null,
    session_conformance: isRecord(raw.session_conformance) ? raw.session_conformance : null,
    cdal_run_id: asString(raw.cdal_run_id) ?? null,
    contract_id: asString(raw.contract_id) ?? null,
    result_status: asString(raw.result_status) ?? null,
    proof_present: asBoolean(raw.proof_present),
    proof_run_id: asString(raw.proof_run_id) ?? null,
    proof_status: asString(raw.proof_status) ?? null,
    proof_risk_class: asString(raw.proof_risk_class) ?? null,
    proof_execution_mode: asString(raw.proof_execution_mode) ?? null,
    proof_evidence_count: asNumber(raw.proof_evidence_count),
    checkpoint_ref: asString(raw.checkpoint_ref) ?? null,
    tool_trace_refs: extractArray(raw.tool_trace_refs)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    raw_evidence_refs: extractArray(raw.raw_evidence_refs)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    worker_name: asString(raw.worker_name) ?? null,
    status: asString(raw.status) ?? null,
    mode: asString(raw.mode) ?? null,
    wait_mode: asString(raw.wait_mode) ?? null,
    trace_capability: asString(raw.trace_capability) ?? null,
    trace_validated: asBoolean(raw.trace_validated),
    validation_failures: extractArray(raw.validation_failures)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    success: asBoolean(raw.success),
    requested_worker_class: asString(raw.requested_worker_class) ?? null,
    requested_worker_size: asString(raw.requested_worker_size) ?? null,
    tool_surface_status: asString(raw.tool_surface_status) ?? null,
    tool_surface_source: asString(raw.tool_surface_source) ?? null,
    tool_surface_names: extractArray(raw.tool_surface_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    tool_surface_masc_names: extractArray(raw.tool_surface_masc_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    tool_surface_shell_names: extractArray(raw.tool_surface_shell_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    tool_surface_count: asNumber(raw.tool_surface_count),
    resolved_runtime: asString(raw.resolved_runtime) ?? null,
    resolved_model: asString(raw.resolved_model) ?? null,
    routing_reason: asString(raw.routing_reason) ?? null,
    tool_names: extractArray(raw.tool_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    tool_call_count: asNumber(raw.tool_call_count),
    output_preview: asString(raw.output_preview) ?? null,
    record_count: asNumber(raw.record_count),
    assistant_block_count: asNumber(raw.assistant_block_count),
    final_text: asString(raw.final_text) ?? null,
    stop_reason: asString(raw.stop_reason) ?? null,
    failure_reason: asString(raw.failure_reason) ?? null,
    error: asString(raw.error) ?? null,
    evidence_refs: extractArray(raw.evidence_refs)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    ts_iso: asString(raw.ts_iso) ?? null,
  }
}

function normalizeWorkerReadiness(raw: unknown): DashboardMissionWorkerReadiness | null {
  if (!isRecord(raw)) return null
  const workerName = asString(raw.worker_name)
  if (!workerName) return null
  return {
    worker_name: workerName,
    spawn_role: asString(raw.spawn_role) ?? null,
    runtime_pool: asString(raw.runtime_pool) ?? null,
    routing_reason: asString(raw.routing_reason) ?? null,
    has_meta: asBoolean(raw.has_meta),
    has_checkpoint: asBoolean(raw.has_checkpoint),
    in_flight: asBoolean(raw.in_flight),
    delegate_ready: asBoolean(raw.delegate_ready),
    blocked_reason: asString(raw.blocked_reason) ?? null,
    guidance: asString(raw.guidance) ?? null,
  }
}

function normalizeSessionWorkerRuns(raw: unknown): DashboardMissionSessionWorkerRuns | null {
  if (!isRecord(raw)) return null
  return {
    requested_count: asNumber(raw.requested_count),
    completed_success_count: asNumber(raw.completed_success_count),
    completed_failed_count: asNumber(raw.completed_failed_count),
    in_flight_count: asNumber(raw.in_flight_count),
    in_flight_run_ids: extractArray(raw.in_flight_run_ids)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    in_flight_actor_names: extractArray(raw.in_flight_actor_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    ready_worker_count: asNumber(raw.ready_worker_count),
    ready_worker_names: extractArray(raw.ready_worker_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    delegate_ready_worker_names: extractArray(raw.delegate_ready_worker_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    blocked_worker_names: extractArray(raw.blocked_worker_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    pending_worker_count: asNumber(raw.pending_worker_count),
    pending_worker_names: extractArray(raw.pending_worker_names)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    worker_readiness: extractArray(raw.worker_readiness)
      .map(normalizeWorkerReadiness)
      .filter((item): item is DashboardMissionWorkerReadiness => item !== null),
    recent_runs: extractArray(raw.recent_runs)
      .map(normalizeWorkerRunEvidence)
      .filter((item): item is DashboardProofWorkerRunEvidence => item !== null),
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
    context_ratio: asNumber(raw.context_ratio),
    generation: asNumber(raw.generation),
    active_goal_ids: extractArray(raw.active_goal_ids)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: asString(raw.model),
    runtime_trust: normalizeKeeperTrust(raw.runtime_trust ?? raw.trust),
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
    pending_confirms: extractArray(root.pending_confirms)
      .map(normalizePendingConfirmation)
      .filter((item): item is PendingConfirmation => item !== null),
    available_actions: extractArray(root.available_actions)
      .map(normalizeActionDescriptor)
      .filter((item): item is OperatorActionDescriptor => item !== null),
  }
}

export function normalizeMission(raw: unknown): DashboardMissionResponse {
  const root = isRecord(raw) ? raw : {}
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
    sessions: sessionCards,
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

export function normalizeMissionSessionDetail(raw: unknown): DashboardMissionSessionDetailResponse {
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
    worker_runs: normalizeSessionWorkerRuns(root.worker_runs),
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
    criteria: extractArray(root.criteria)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    basis: {
      namespace: asString(basis.namespace) ?? null,
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
