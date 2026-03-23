import { isRecord, asString, asNumber, asBoolean, asStringArray } from './components/common/normalize'
import type {
  CommandPlaneAlert,
  CommandPlaneAlertsResponse,
  CommandPlaneBudgetEnvelope,
  CommandPlaneCapacityResponse,
  CommandPlaneCapacityRow,
  CommandPlaneChainRecord,
  CommandPlaneDecisionRecord,
  CommandPlaneDecisionsResponse,
  CommandPlaneDetachmentsResponse,
  CommandPlaneDetachmentCard,
  CommandPlaneDetachmentRecord,
  CommandPlaneMicroarchSummary,
  CommandPlaneOperationCard,
  CommandPlaneOperationRecord,
  CommandPlaneOperationsResponse,
  CommandPlanePolicyEnvelope,
  CommandPlaneTopologyResponse,
  CommandPlaneTopologySummary,
  CommandPlaneTraceEvent,
  CommandPlaneTracesResponse,
  CommandPlaneTreeNode,
  CommandPlaneUnitRecord,
  CommandPlaneUnitKind,
} from './types'

export function normalizePolicy(raw: unknown): CommandPlanePolicyEnvelope | undefined {
  if (!isRecord(raw)) return undefined
  return {
    policy_class: asString(raw.policy_class),
    approval_class: asString(raw.approval_class),
    tool_allowlist: asStringArray(raw.tool_allowlist),
    model_allowlist: asStringArray(raw.model_allowlist),
    requires_human_for: asStringArray(raw.requires_human_for),
    escalation_timeout_sec: asNumber(raw.escalation_timeout_sec),
    kill_switch: asBoolean(raw.kill_switch),
    frozen: asBoolean(raw.frozen),
  }
}

export function normalizeBudget(raw: unknown): CommandPlaneBudgetEnvelope | undefined {
  if (!isRecord(raw)) return undefined
  return {
    headcount_cap: asNumber(raw.headcount_cap),
    active_operation_cap: asNumber(raw.active_operation_cap),
    max_cost_usd: asNumber(raw.max_cost_usd),
    max_tokens: asNumber(raw.max_tokens),
  }
}

export function normalizeUnitRecord(raw: unknown): CommandPlaneUnitRecord | null {
  if (!isRecord(raw)) return null
  const unitId = asString(raw.unit_id)
  const label = asString(raw.label)
  const kind = asString(raw.kind) as CommandPlaneUnitKind | undefined
  if (!unitId || !label || !kind) return null
  return {
    unit_id: unitId,
    label,
    kind,
    parent_unit_id: asString(raw.parent_unit_id) ?? null,
    leader_id: asString(raw.leader_id) ?? null,
    roster: asStringArray(raw.roster),
    capability_profile: asStringArray(raw.capability_profile),
    source: asString(raw.source),
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
    policy: normalizePolicy(raw.policy),
    budget: normalizeBudget(raw.budget),
  }
}

export function normalizeTreeNode(raw: unknown): CommandPlaneTreeNode | null {
  if (!isRecord(raw)) return null
  const unit = normalizeUnitRecord(raw.unit)
  if (!unit) return null
  return {
    unit,
    leader_status: asString(raw.leader_status),
    roster_total: asNumber(raw.roster_total),
    roster_live: asNumber(raw.roster_live),
    active_operation_count: asNumber(raw.active_operation_count),
    health: asString(raw.health),
    reasons: asStringArray(raw.reasons),
    children: Array.isArray(raw.children)
      ? raw.children
          .map(normalizeTreeNode)
          .filter((item): item is CommandPlaneTreeNode => item !== null)
      : [],
  }
}

export function normalizeTopologySummary(raw: unknown): CommandPlaneTopologySummary | undefined {
  if (!isRecord(raw)) return undefined
  return {
    total_units: asNumber(raw.total_units),
    company_count: asNumber(raw.company_count),
    platoon_count: asNumber(raw.platoon_count),
    squad_count: asNumber(raw.squad_count),
    leaf_agent_unit_count: asNumber(raw.leaf_agent_unit_count),
    live_agent_count: asNumber(raw.live_agent_count),
    managed_unit_count: asNumber(raw.managed_unit_count),
    active_operation_count: asNumber(raw.active_operation_count),
  }
}

export function normalizeTopology(raw: unknown): CommandPlaneTopologyResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    source: asString(root.source),
    summary: normalizeTopologySummary(root.summary),
    units: Array.isArray(root.units)
      ? root.units
          .map(normalizeTreeNode)
          .filter((item): item is CommandPlaneTreeNode => item !== null)
      : [],
  }
}

export function normalizeChainRecord(raw: unknown): CommandPlaneChainRecord | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const status = asString(raw.status)
  if (!kind || !status) return null
  return {
    kind,
    chain_id: asString(raw.chain_id) ?? null,
    goal: asString(raw.goal) ?? null,
    run_id: asString(raw.run_id) ?? null,
    status,
    viewer_path: asString(raw.viewer_path) ?? null,
    last_sync_at: asString(raw.last_sync_at) ?? null,
  }
}

export function normalizeOperationRecord(raw: unknown): CommandPlaneOperationRecord | null {
  if (!isRecord(raw)) return null
  const operationId = asString(raw.operation_id)
  const objective = asString(raw.objective)
  const assignedUnitId = asString(raw.assigned_unit_id)
  const traceId = asString(raw.trace_id)
  const status = asString(raw.status)
  if (!operationId || !objective || !assignedUnitId || !traceId || !status) return null
  return {
    operation_id: operationId,
    objective,
    assigned_unit_id: assignedUnitId,
    policy_class: asString(raw.policy_class),
    budget_class: asString(raw.budget_class),
    detachment_session_id: asString(raw.detachment_session_id) ?? null,
    trace_id: traceId,
    checkpoint_ref: asString(raw.checkpoint_ref) ?? null,
    active_goal_ids: asStringArray(raw.active_goal_ids),
    note: asString(raw.note) ?? null,
    created_by: asString(raw.created_by),
    source: asString(raw.source),
    status,
    chain: normalizeChainRecord(raw.chain),
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
  }
}

export function normalizeOperationCard(raw: unknown): CommandPlaneOperationCard | null {
  if (!isRecord(raw)) return null
  const operation = normalizeOperationRecord(raw.operation)
  if (!operation) return null
  return {
    operation,
    assigned_unit_label: asString(raw.assigned_unit_label),
  }
}

function normalizeMicroarchSignal(raw: unknown) {
  if (!isRecord(raw)) return undefined
  return {
    tone: asString(raw.tone),
    pending_ops: asNumber(raw.pending_ops),
    blocked_ops: asNumber(raw.blocked_ops),
    in_flight_ops: asNumber(raw.in_flight_ops),
    pipeline_stalls: asNumber(raw.pipeline_stalls),
    bus_traffic: asNumber(raw.bus_traffic),
    l1_hit_rate: asNumber(raw.l1_hit_rate),
    invalidation_count: asNumber(raw.invalidation_count),
    current_pending: asNumber(raw.current_pending),
    current_in_flight: asNumber(raw.current_in_flight),
    cdb_wakeups: asNumber(raw.cdb_wakeups),
    total_stolen: asNumber(raw.total_stolen),
    avg_best_score: asNumber(raw.avg_best_score),
    avg_candidate_count: asNumber(raw.avg_candidate_count),
    best_first_operations: asNumber(raw.best_first_operations),
    active_sessions: asNumber(raw.active_sessions),
    commit_rate: asNumber(raw.commit_rate),
    total_speculations: asNumber(raw.total_speculations),
  }
}

export function normalizeMicroarch(raw: unknown): CommandPlaneMicroarchSummary | undefined {
  if (!isRecord(raw)) return undefined
  const pipeline = isRecord(raw.pipeline) ? raw.pipeline : undefined
  const cache = isRecord(raw.cache) ? raw.cache : undefined
  const ooo = isRecord(raw.ooo) ? raw.ooo : undefined
  const speculative = isRecord(raw.speculative) ? raw.speculative : undefined
  const search = isRecord(raw.search_fabric) ? raw.search_fabric : undefined
  const signals = isRecord(raw.signals) ? raw.signals : undefined
  return {
    pipeline: pipeline
      ? {
          total_ops: asNumber(pipeline.total_ops),
          completed_ops: asNumber(pipeline.completed_ops),
          stalled_cycles: asNumber(pipeline.stalled_cycles),
          hazards_detected: asNumber(pipeline.hazards_detected),
          forwarding_used: asNumber(pipeline.forwarding_used),
          pipeline_flushes: asNumber(pipeline.pipeline_flushes),
          ipc: asNumber(pipeline.ipc),
        }
      : undefined,
    cache: cache
      ? {
          total_reads: asNumber(cache.total_reads),
          total_writes: asNumber(cache.total_writes),
          l1_hit_rate: asNumber(cache.l1_hit_rate),
          invalidation_count: asNumber(cache.invalidation_count),
          writeback_count: asNumber(cache.writeback_count),
          bus_traffic: asNumber(cache.bus_traffic),
        }
      : undefined,
    ooo: ooo
      ? {
          agent_count: asNumber(ooo.agent_count),
          total_added: asNumber(ooo.total_added),
          total_issued: asNumber(ooo.total_issued),
          total_completed: asNumber(ooo.total_completed),
          total_stolen: asNumber(ooo.total_stolen),
          cdb_wakeups: asNumber(ooo.cdb_wakeups),
          stall_cycles: asNumber(ooo.stall_cycles),
          global_cdb_events: asNumber(ooo.global_cdb_events),
          current_pending: asNumber(ooo.current_pending),
          current_in_flight: asNumber(ooo.current_in_flight),
        }
      : undefined,
    speculative: speculative
      ? {
          total_speculations: asNumber(speculative.total_speculations),
          total_commits: asNumber(speculative.total_commits),
          total_aborts: asNumber(speculative.total_aborts),
          commit_rate: asNumber(speculative.commit_rate),
          total_fast_calls: asNumber(speculative.total_fast_calls),
          total_cost_usd: asNumber(speculative.total_cost_usd),
          active_sessions: asNumber(speculative.active_sessions),
        }
      : undefined,
    search_fabric: search
      ? {
          total_operations: asNumber(search.total_operations),
          best_first_operations: asNumber(search.best_first_operations),
          legacy_operations: asNumber(search.legacy_operations),
          blocked_operations: asNumber(search.blocked_operations),
          ready_operations: asNumber(search.ready_operations),
          research_pipeline_operations: asNumber(search.research_pipeline_operations),
          avg_candidate_count: asNumber(search.avg_candidate_count),
          avg_best_score: asNumber(search.avg_best_score),
          top_stage: asString(search.top_stage) ?? null,
        }
      : undefined,
    signals: signals
      ? {
          issue_pressure: normalizeMicroarchSignal(signals.issue_pressure),
          cache_contention: normalizeMicroarchSignal(signals.cache_contention),
          scheduler_efficiency: normalizeMicroarchSignal(signals.scheduler_efficiency),
          routing_confidence: normalizeMicroarchSignal(signals.routing_confidence),
          speculative_posture: normalizeMicroarchSignal(signals.speculative_posture),
        }
      : undefined,
  }
}

export function normalizeOperations(raw: unknown): CommandPlaneOperationsResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    summary: summary
      ? {
          total: asNumber(summary.total),
          active: asNumber(summary.active),
          paused: asNumber(summary.paused),
          managed: asNumber(summary.managed),
          projected: asNumber(summary.projected),
        }
      : undefined,
    microarch: normalizeMicroarch(root.microarch),
    operations: Array.isArray(root.operations)
      ? root.operations
          .map(normalizeOperationCard)
          .filter((item): item is CommandPlaneOperationCard => item !== null)
      : [],
  }
}

export function normalizeDetachmentRecord(raw: unknown): CommandPlaneDetachmentRecord | null {
  if (!isRecord(raw)) return null
  const detachmentId = asString(raw.detachment_id)
  const operationId = asString(raw.operation_id)
  const assignedUnitId = asString(raw.assigned_unit_id)
  if (!detachmentId || !operationId || !assignedUnitId) return null
  return {
    detachment_id: detachmentId,
    operation_id: operationId,
    assigned_unit_id: assignedUnitId,
    leader_id: asString(raw.leader_id) ?? null,
    roster: asStringArray(raw.roster),
    session_id: asString(raw.session_id) ?? null,
    checkpoint_ref: asString(raw.checkpoint_ref) ?? null,
    runtime_kind: asString(raw.runtime_kind) ?? null,
    runtime_ref: asString(raw.runtime_ref) ?? null,
    source: asString(raw.source),
    status: asString(raw.status),
    last_event_at: asString(raw.last_event_at) ?? null,
    last_progress_at: asString(raw.last_progress_at) ?? null,
    heartbeat_deadline: asString(raw.heartbeat_deadline) ?? null,
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
  }
}

export function normalizeDetachmentCard(raw: unknown): CommandPlaneDetachmentCard | null {
  if (!isRecord(raw)) return null
  const detachment = normalizeDetachmentRecord(raw.detachment)
  if (!detachment) return null
  return {
    detachment,
    assigned_unit_label: asString(raw.assigned_unit_label),
    operation: normalizeOperationRecord(raw.operation),
  }
}

export function normalizeDetachments(raw: unknown): CommandPlaneDetachmentsResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    summary: summary
      ? {
          total: asNumber(summary.total),
          active: asNumber(summary.active),
          projected: asNumber(summary.projected),
        }
      : undefined,
    detachments: Array.isArray(root.detachments)
      ? root.detachments
          .map(normalizeDetachmentCard)
          .filter((item): item is CommandPlaneDetachmentCard => item !== null)
      : [],
  }
}

export function normalizeDecision(raw: unknown): CommandPlaneDecisionRecord | null {
  if (!isRecord(raw)) return null
  const decisionId = asString(raw.decision_id)
  const traceId = asString(raw.trace_id)
  const requestedAction = asString(raw.requested_action)
  const scopeType = asString(raw.scope_type)
  const scopeId = asString(raw.scope_id)
  if (!decisionId || !traceId || !requestedAction || !scopeType || !scopeId) return null
  return {
    decision_id: decisionId,
    trace_id: traceId,
    requested_action: requestedAction,
    scope_type: scopeType,
    scope_id: scopeId,
    operation_id: asString(raw.operation_id) ?? null,
    target_unit_id: asString(raw.target_unit_id) ?? null,
    requested_by: asString(raw.requested_by),
    status: asString(raw.status),
    reason: asString(raw.reason) ?? null,
    source: asString(raw.source),
    detail: raw.detail,
    created_at: asString(raw.created_at),
    decided_at: asString(raw.decided_at) ?? null,
    expires_at: asString(raw.expires_at) ?? null,
  }
}

export function normalizeDecisions(raw: unknown): CommandPlaneDecisionsResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    summary: summary
      ? {
          total: asNumber(summary.total),
          pending: asNumber(summary.pending),
          approved: asNumber(summary.approved),
          denied: asNumber(summary.denied),
        }
      : undefined,
    decisions: Array.isArray(root.decisions)
      ? root.decisions
          .map(normalizeDecision)
          .filter((item): item is CommandPlaneDecisionRecord => item !== null)
      : [],
  }
}

export function normalizeCapacityRow(raw: unknown): CommandPlaneCapacityRow | null {
  if (!isRecord(raw)) return null
  const unit = normalizeUnitRecord(raw.unit)
  if (!unit) return null
  return {
    unit,
    roster_total: asNumber(raw.roster_total),
    roster_live: asNumber(raw.roster_live),
    headcount_cap: asNumber(raw.headcount_cap),
    active_operations: asNumber(raw.active_operations),
    active_operation_cap: asNumber(raw.active_operation_cap),
    utilization: asNumber(raw.utilization),
  }
}

export function normalizeCapacity(raw: unknown): CommandPlaneCapacityResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    capacity: Array.isArray(root.capacity)
      ? root.capacity
          .map(normalizeCapacityRow)
          .filter((item): item is CommandPlaneCapacityRow => item !== null)
      : [],
  }
}

export function normalizeAlert(raw: unknown): CommandPlaneAlert | null {
  if (!isRecord(raw)) return null
  const alertId = asString(raw.alert_id)
  if (!alertId) return null
  return {
    alert_id: alertId,
    severity: asString(raw.severity),
    kind: asString(raw.kind),
    scope_type: asString(raw.scope_type),
    scope_id: asString(raw.scope_id),
    title: asString(raw.title),
    detail: asString(raw.detail),
    timestamp: asString(raw.timestamp),
  }
}

export function normalizeAlerts(raw: unknown): CommandPlaneAlertsResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    summary: summary
      ? {
          total: asNumber(summary.total),
          bad: asNumber(summary.bad),
          warn: asNumber(summary.warn),
        }
      : undefined,
    alerts: Array.isArray(root.alerts)
      ? root.alerts
          .map(normalizeAlert)
          .filter((item): item is CommandPlaneAlert => item !== null)
      : [],
  }
}

export function normalizeTrace(raw: unknown): CommandPlaneTraceEvent | null {
  if (!isRecord(raw)) return null
  const eventId = asString(raw.event_id)
  const traceId = asString(raw.trace_id)
  const eventType = asString(raw.event_type)
  if (!eventId || !traceId || !eventType) return null
  return {
    event_id: eventId,
    trace_id: traceId,
    event_type: eventType,
    operation_id: asString(raw.operation_id) ?? null,
    unit_id: asString(raw.unit_id) ?? null,
    actor: asString(raw.actor) ?? null,
    source: asString(raw.source),
    timestamp: asString(raw.timestamp),
    detail: raw.detail,
  }
}

export function normalizeTraces(raw: unknown): CommandPlaneTracesResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    events: Array.isArray(root.events)
      ? root.events
          .map(normalizeTrace)
          .filter((item): item is CommandPlaneTraceEvent => item !== null)
      : [],
  }
}
