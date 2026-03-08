import { signal } from '@preact/signals'
import {
  fetchCommandPlaneHelp,
  fetchCommandPlaneSnapshot,
  fetchCommandPlaneSwarm,
  runCommandPlaneAction,
} from './api'
import type {
  CommandPlaneAlert,
  CommandPlaneAlertsResponse,
  CommandPlaneBudgetEnvelope,
  CommandPlaneHelpConcept,
  CommandPlaneHelpDocLink,
  CommandPlaneHelpExample,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpResponse,
  CommandPlaneHelpStep,
  CommandPlaneHelpToolGroup,
  CommandPlaneCapacityResponse,
  CommandPlaneCapacityRow,
  CommandPlaneDecisionRecord,
  CommandPlaneDecisionsResponse,
  CommandPlaneDetachmentsResponse,
  CommandPlaneDetachmentCard,
  CommandPlaneDetachmentRecord,
  CommandPlaneOperationCard,
  CommandPlaneOperationRecord,
  CommandPlaneOperationsResponse,
  CommandPlanePolicyEnvelope,
  CommandPlaneSnapshot,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmStatus,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmMessage,
  CommandPlaneSwarmProvider,
  CommandPlaneSwarmProviderSample,
  CommandPlaneSwarmResponse,
  CommandPlaneSwarmWorker,
  CommandPlaneSurface,
  CommandPlaneTopologyResponse,
  CommandPlaneTopologySummary,
  CommandPlaneTraceEvent,
  CommandPlaneTracesResponse,
  CommandPlaneTreeNode,
  CommandPlaneUnitRecord,
  CommandPlaneUnitKind,
} from './types'

export const commandPlaneSnapshot = signal<CommandPlaneSnapshot | null>(null)
export const commandPlaneLoading = signal(false)
export const commandPlaneError = signal<string | null>(null)
export const commandPlaneActionBusy = signal<string | null>(null)
export const commandPlaneActionError = signal<string | null>(null)
export const commandPlaneSurface = signal<CommandPlaneSurface>('operations')
export const commandPlaneHelp = signal<CommandPlaneHelpResponse | null>(null)
export const commandPlaneHelpLoading = signal(false)
export const commandPlaneHelpError = signal<string | null>(null)
export const commandPlaneSwarm = signal<CommandPlaneSwarmResponse | null>(null)
export const commandPlaneSwarmLoading = signal(false)
export const commandPlaneSwarmError = signal<string | null>(null)

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(Boolean)
}

function currentSwarmRunId(): string | undefined {
  if (typeof window === 'undefined') return undefined
  const params = new URLSearchParams(window.location.search)
  const value = params.get('run_id') ?? undefined
  return value && value.trim() !== '' ? value.trim() : undefined
}

function normalizePolicy(raw: unknown): CommandPlanePolicyEnvelope | undefined {
  if (!isRecord(raw)) return undefined
  return {
    policy_class: asString(raw.policy_class),
    approval_class: asString(raw.approval_class),
    tool_allowlist: asStringArray(raw.tool_allowlist),
    model_allowlist: asStringArray(raw.model_allowlist),
    requires_human_for: asStringArray(raw.requires_human_for),
    autonomy_level: asString(raw.autonomy_level),
    escalation_timeout_sec: asNumber(raw.escalation_timeout_sec),
    kill_switch: asBoolean(raw.kill_switch),
    frozen: asBoolean(raw.frozen),
  }
}

function normalizeBudget(raw: unknown): CommandPlaneBudgetEnvelope | undefined {
  if (!isRecord(raw)) return undefined
  return {
    headcount_cap: asNumber(raw.headcount_cap),
    active_operation_cap: asNumber(raw.active_operation_cap),
    max_cost_usd: asNumber(raw.max_cost_usd),
    max_tokens: asNumber(raw.max_tokens),
  }
}

function normalizeUnitRecord(raw: unknown): CommandPlaneUnitRecord | null {
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

function normalizeTreeNode(raw: unknown): CommandPlaneTreeNode | null {
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

function normalizeTopologySummary(raw: unknown): CommandPlaneTopologySummary | undefined {
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

function normalizeTopology(raw: unknown): CommandPlaneTopologyResponse {
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

function normalizeOperationRecord(raw: unknown): CommandPlaneOperationRecord | null {
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
    autonomy_level: asString(raw.autonomy_level),
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
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
  }
}

function normalizeOperationCard(raw: unknown): CommandPlaneOperationCard | null {
  if (!isRecord(raw)) return null
  const operation = normalizeOperationRecord(raw.operation)
  if (!operation) return null
  return {
    operation,
    assigned_unit_label: asString(raw.assigned_unit_label),
  }
}

function normalizeOperations(raw: unknown): CommandPlaneOperationsResponse {
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
    operations: Array.isArray(root.operations)
      ? root.operations
          .map(normalizeOperationCard)
          .filter((item): item is CommandPlaneOperationCard => item !== null)
      : [],
  }
}

function normalizeDetachmentRecord(raw: unknown): CommandPlaneDetachmentRecord | null {
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

function normalizeDetachmentCard(raw: unknown): CommandPlaneDetachmentCard | null {
  if (!isRecord(raw)) return null
  const detachment = normalizeDetachmentRecord(raw.detachment)
  if (!detachment) return null
  return {
    detachment,
    assigned_unit_label: asString(raw.assigned_unit_label),
    operation: normalizeOperationRecord(raw.operation),
  }
}

function normalizeDetachments(raw: unknown): CommandPlaneDetachmentsResponse {
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

function normalizeDecision(raw: unknown): CommandPlaneDecisionRecord | null {
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

function normalizeDecisions(raw: unknown): CommandPlaneDecisionsResponse {
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

function normalizeCapacityRow(raw: unknown): CommandPlaneCapacityRow | null {
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

function normalizeCapacity(raw: unknown): CommandPlaneCapacityResponse {
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

function normalizeAlert(raw: unknown): CommandPlaneAlert | null {
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

function normalizeAlerts(raw: unknown): CommandPlaneAlertsResponse {
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

function normalizeTrace(raw: unknown): CommandPlaneTraceEvent | null {
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

function normalizeTraces(raw: unknown): CommandPlaneTracesResponse {
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

function normalizeSwarmFlag(raw: unknown): CommandPlaneSwarmFlag | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity)
  const summary = asString(raw.summary)
  if (!code || !severity || !summary) return null
  return { code, severity, summary }
}

function normalizeSwarmLane(raw: unknown): CommandPlaneSwarmLane | null {
  if (!isRecord(raw)) return null
  const laneId = asString(raw.lane_id)
  const label = asString(raw.label)
  const kind = asString(raw.kind)
  const phase = asString(raw.phase)
  const motionState = asString(raw.motion_state)
  const sourceOfTruth = asString(raw.source_of_truth)
  const movementReason = asString(raw.movement_reason)
  const currentStep = asString(raw.current_step)
  if (!laneId || !label || !kind || !phase || !motionState || !sourceOfTruth || !movementReason || !currentStep) {
    return null
  }
  const counts = isRecord(raw.counts) ? raw.counts : {}
  return {
    lane_id: laneId,
    label,
    kind,
    present: asBoolean(raw.present) ?? false,
    phase,
    motion_state: motionState,
    source_of_truth: sourceOfTruth,
    last_movement_at: asString(raw.last_movement_at) ?? null,
    movement_reason: movementReason,
    current_step: currentStep,
    blockers: asStringArray(raw.blockers),
    counts: {
      operations: asNumber(counts.operations),
      detachments: asNumber(counts.detachments),
      workers: asNumber(counts.workers),
      approvals: asNumber(counts.approvals),
      alerts: asNumber(counts.alerts),
    },
    hard_flags: Array.isArray(raw.hard_flags)
      ? raw.hard_flags
          .map(normalizeSwarmFlag)
          .filter((item): item is CommandPlaneSwarmFlag => item !== null)
      : [],
  }
}

function normalizeSwarmTimelineEvent(raw: unknown): CommandPlaneSwarmTimelineEvent | null {
  if (!isRecord(raw)) return null
  const eventId = asString(raw.event_id)
  const laneId = asString(raw.lane_id)
  const kind = asString(raw.kind)
  const timestamp = asString(raw.timestamp)
  const title = asString(raw.title)
  const detail = asString(raw.detail)
  const tone = asString(raw.tone)
  const source = asString(raw.source)
  if (!eventId || !laneId || !kind || !timestamp || !title || !detail || !tone || !source) return null
  return { event_id: eventId, lane_id: laneId, kind, timestamp, title, detail, tone, source }
}

function normalizeSwarmGap(raw: unknown): CommandPlaneSwarmGap | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity)
  const summary = asString(raw.summary)
  if (!code || !severity || !summary) return null
  return {
    code,
    severity,
    summary,
    lane_ids: asStringArray(raw.lane_ids),
    count: asNumber(raw.count) ?? 0,
  }
}

function normalizeSwarmStatus(raw: unknown): CommandPlaneSwarmStatus | undefined {
  if (!isRecord(raw)) return undefined
  const overview = isRecord(raw.overview) ? raw.overview : {}
  const gaps = isRecord(raw.gaps) ? raw.gaps : {}
  const recommendation = isRecord(raw.recommended_next_action) ? raw.recommended_next_action : undefined
  return {
    generated_at: asString(raw.generated_at),
    overview: {
      active_lanes: asNumber(overview.active_lanes),
      moving_lanes: asNumber(overview.moving_lanes),
      stalled_lanes: asNumber(overview.stalled_lanes),
      projected_lanes: asNumber(overview.projected_lanes),
      last_movement_at: asString(overview.last_movement_at) ?? null,
    },
    lanes: Array.isArray(raw.lanes)
      ? raw.lanes
          .map(normalizeSwarmLane)
          .filter((item): item is CommandPlaneSwarmLane => item !== null)
      : [],
    timeline: Array.isArray(raw.timeline)
      ? raw.timeline
          .map(normalizeSwarmTimelineEvent)
          .filter((item): item is CommandPlaneSwarmTimelineEvent => item !== null)
      : [],
    gaps: {
      count: asNumber(gaps.count),
      items: Array.isArray(gaps.items)
        ? gaps.items
            .map(normalizeSwarmGap)
            .filter((item): item is CommandPlaneSwarmGap => item !== null)
        : [],
    },
    recommended_next_action: recommendation
      ? {
          tool: asString(recommendation.tool) ?? 'masc_operator_snapshot',
          label: asString(recommendation.label) ?? 'Observe operator state',
          reason: asString(recommendation.reason) ?? '',
          lane_id: asString(recommendation.lane_id) ?? null,
        }
      : undefined,
  }
}

function normalizeSnapshot(raw: unknown): CommandPlaneSnapshot {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: normalizeTopology(root.topology),
    operations: normalizeOperations(root.operations),
    detachments: normalizeDetachments(root.detachments),
    alerts: normalizeAlerts(root.alerts),
    decisions: normalizeDecisions(root.decisions),
    capacity: normalizeCapacity(root.capacity),
    traces: normalizeTraces(root.traces),
    swarm_status: normalizeSwarmStatus(root.swarm_status),
  }
}

function normalizeHelpDoc(raw: unknown): CommandPlaneHelpDocLink | null {
  if (!isRecord(raw)) return null
  const title = asString(raw.title)
  const path = asString(raw.path)
  if (!title || !path) return null
  return { title, path }
}

function normalizeHelpConcept(raw: unknown): CommandPlaneHelpConcept | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  if (!id || !title || !summary) return null
  return { id, title, summary }
}

function normalizeHelpStep(raw: unknown): CommandPlaneHelpStep | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const tool = asString(raw.tool)
  const summary = asString(raw.summary)
  if (!id || !title || !tool || !summary) return null
  return {
    id,
    title,
    tool,
    summary,
    success_signals: asStringArray(raw.success_signals),
    pitfalls: asStringArray(raw.pitfalls),
  }
}

function normalizeHelpPath(raw: unknown): CommandPlaneHelpPath | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const whenToUse = asString(raw.when_to_use)
  if (!id || !title || !summary || !whenToUse) return null
  return {
    id,
    title,
    summary,
    when_to_use: whenToUse,
    steps: Array.isArray(raw.steps)
      ? raw.steps
          .map(normalizeHelpStep)
          .filter((item): item is CommandPlaneHelpStep => item !== null)
      : [],
  }
}

function normalizeHelpToolGroup(raw: unknown): CommandPlaneHelpToolGroup | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const description = asString(raw.description)
  if (!id || !title || !description) return null
  return {
    id,
    title,
    description,
    tools: asStringArray(raw.tools),
  }
}

function normalizeHelpPitfall(raw: unknown): CommandPlaneHelpPitfall | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const symptom = asString(raw.symptom)
  const why = asString(raw.why)
  const fixTool = asString(raw.fix_tool)
  const fixSummary = asString(raw.fix_summary)
  if (!id || !title || !symptom || !why || !fixTool || !fixSummary) return null
  return {
    id,
    title,
    symptom,
    why,
    fix_tool: fixTool,
    fix_summary: fixSummary,
  }
}

function normalizeHelpExample(raw: unknown): CommandPlaneHelpExample | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const pathId = asString(raw.path_id)
  const transport = asString(raw.transport)
  if (!id || !title || !pathId || !transport) return null
  return {
    id,
    title,
    path_id: pathId,
    transport,
    request: raw.request,
    response: raw.response,
    notes: asStringArray(raw.notes),
  }
}

function normalizeHelp(raw: unknown): CommandPlaneHelpResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    docs: Array.isArray(root.docs)
      ? root.docs
          .map(normalizeHelpDoc)
          .filter((item): item is CommandPlaneHelpDocLink => item !== null)
      : [],
    concepts: Array.isArray(root.concepts)
      ? root.concepts
          .map(normalizeHelpConcept)
          .filter((item): item is CommandPlaneHelpConcept => item !== null)
      : [],
    golden_paths: Array.isArray(root.golden_paths)
      ? root.golden_paths
          .map(normalizeHelpPath)
          .filter((item): item is CommandPlaneHelpPath => item !== null)
      : [],
    tool_groups: Array.isArray(root.tool_groups)
      ? root.tool_groups
          .map(normalizeHelpToolGroup)
          .filter((item): item is CommandPlaneHelpToolGroup => item !== null)
      : [],
    pitfalls: Array.isArray(root.pitfalls)
      ? root.pitfalls
          .map(normalizeHelpPitfall)
          .filter((item): item is CommandPlaneHelpPitfall => item !== null)
      : [],
    examples: Array.isArray(root.examples)
      ? root.examples
          .map(normalizeHelpExample)
          .filter((item): item is CommandPlaneHelpExample => item !== null)
      : [],
  }
}

function normalizeSwarmChecklistItem(raw: unknown): CommandPlaneSwarmChecklistItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const status = asString(raw.status) as CommandPlaneSwarmChecklistItem['status'] | undefined
  const detail = asString(raw.detail)
  const nextTool = asString(raw.next_tool)
  if (!id || !title || !status || !detail || !nextTool) return null
  return { id, title, status, detail, next_tool: nextTool }
}

function normalizeSwarmBlocker(raw: unknown): CommandPlaneSwarmBlocker | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity) as CommandPlaneSwarmBlocker['severity'] | undefined
  const title = asString(raw.title)
  const detail = asString(raw.detail)
  const nextTool = asString(raw.next_tool)
  if (!code || !severity || !title || !detail || !nextTool) return null
  return { code, severity, title, detail, next_tool: nextTool }
}

function normalizeSwarmMessage(raw: unknown): CommandPlaneSwarmMessage | null {
  if (!isRecord(raw)) return null
  const from = asString(raw.from)
  const content = asString(raw.content)
  const timestamp = asString(raw.timestamp)
  const seq = asNumber(raw.seq)
  if (!from || !content || !timestamp || seq == null) return null
  return { seq, from, content, timestamp }
}

function normalizeSwarmWorker(raw: unknown): CommandPlaneSwarmWorker | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const role = asString(raw.role)
  const lane = asString(raw.lane)
  const status = asString(raw.status)
  const claimMarker = asString(raw.claim_marker)
  const doneMarker = asString(raw.done_marker)
  const finalMarker = asString(raw.final_marker)
  if (!name || !role || !lane || !status || !claimMarker || !doneMarker || !finalMarker) return null
  const lastMessage = (() => {
    if (!isRecord(raw.last_message)) return null
    const seq = asNumber(raw.last_message.seq)
    const content = asString(raw.last_message.content)
    const timestamp = asString(raw.last_message.timestamp)
    if (seq == null || !content || !timestamp) return null
    return { seq, content, timestamp }
  })()
  return {
    name,
    role,
    lane,
    joined: asBoolean(raw.joined) ?? false,
    live_presence: asBoolean(raw.live_presence) ?? false,
    completed: asBoolean(raw.completed) ?? false,
    status,
    current_task: asString(raw.current_task) ?? null,
    bound_task_id: asString(raw.bound_task_id) ?? null,
    bound_task_title: asString(raw.bound_task_title) ?? null,
    bound_task_status: asString(raw.bound_task_status) ?? null,
    current_task_matches_run: asBoolean(raw.current_task_matches_run) ?? false,
    squad_member: asBoolean(raw.squad_member) ?? false,
    detachment_member: asBoolean(raw.detachment_member) ?? false,
    last_seen: asString(raw.last_seen) ?? null,
    heartbeat_age_sec: asNumber(raw.heartbeat_age_sec) ?? null,
    heartbeat_fresh: asBoolean(raw.heartbeat_fresh) ?? false,
    claim_marker_seen: asBoolean(raw.claim_marker_seen) ?? false,
    done_marker_seen: asBoolean(raw.done_marker_seen) ?? false,
    final_marker_seen: asBoolean(raw.final_marker_seen) ?? false,
    claim_marker: claimMarker,
    done_marker: doneMarker,
    final_marker: finalMarker,
    last_message: lastMessage,
  }
}

function normalizeSwarmProvider(raw: unknown): CommandPlaneSwarmProvider | undefined {
  if (!isRecord(raw)) return undefined
  const timeline = Array.isArray(raw.timeline)
    ? raw.timeline
        .map(sample => {
          if (!isRecord(sample)) return null
          const timestamp = asString(sample.timestamp)
          const activeSlots = asNumber(sample.active_slots)
          if (!timestamp || activeSlots == null) return null
          const activeSlotIds = Array.isArray(sample.active_slot_ids)
            ? sample.active_slot_ids
                .map(value => (typeof value === 'number' && Number.isFinite(value) ? value : null))
                .filter((value): value is number => value != null)
            : []
          return { timestamp, active_slots: activeSlots, active_slot_ids: activeSlotIds }
        })
        .filter((sample): sample is CommandPlaneSwarmProviderSample => sample !== null)
    : []
  return {
    slot_url: asString(raw.slot_url) ?? null,
    total_slots: asNumber(raw.total_slots),
    ctx_per_slot: asNumber(raw.ctx_per_slot),
    active_slots_now: asNumber(raw.active_slots_now),
    peak_active_slots: asNumber(raw.peak_active_slots),
    sample_count: asNumber(raw.sample_count),
    last_sample_at: asString(raw.last_sample_at) ?? null,
    timeline,
  }
}

function normalizeSwarm(raw: unknown): CommandPlaneSwarmResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    run_id: asString(root.run_id),
    room_id: asString(root.room_id),
    operation_id: asString(root.operation_id) ?? null,
    recommended_next_tool: asString(root.recommended_next_tool),
    summary: summary
      ? {
          expected_workers: asNumber(summary.expected_workers),
          joined_workers: asNumber(summary.joined_workers),
          live_workers: asNumber(summary.live_workers),
          squad_roster_size: asNumber(summary.squad_roster_size),
          detachment_roster_size: asNumber(summary.detachment_roster_size),
          current_task_bound: asNumber(summary.current_task_bound),
          fresh_heartbeats: asNumber(summary.fresh_heartbeats),
          claim_markers_seen: asNumber(summary.claim_markers_seen),
          done_markers_seen: asNumber(summary.done_markers_seen),
          final_markers_seen: asNumber(summary.final_markers_seen),
          completed_workers: asNumber(summary.completed_workers),
          peak_hot_slots: asNumber(summary.peak_hot_slots),
          hot_window_ok: asBoolean(summary.hot_window_ok),
          pass_hot_concurrency: asBoolean(summary.pass_hot_concurrency),
          pass_end_to_end: asBoolean(summary.pass_end_to_end),
          pending_decisions: asNumber(summary.pending_decisions),
          pass: asBoolean(summary.pass),
        }
      : undefined,
    provider: normalizeSwarmProvider(root.provider),
    operation: normalizeOperationRecord(root.operation),
    squad: normalizeUnitRecord(root.squad),
    detachment: normalizeDetachmentRecord(root.detachment),
    workers: Array.isArray(root.workers)
      ? root.workers
          .map(normalizeSwarmWorker)
          .filter((item): item is CommandPlaneSwarmWorker => item !== null)
      : [],
    checklist: Array.isArray(root.checklist)
      ? root.checklist
          .map(normalizeSwarmChecklistItem)
          .filter((item): item is CommandPlaneSwarmChecklistItem => item !== null)
      : [],
    blockers: Array.isArray(root.blockers)
      ? root.blockers
          .map(normalizeSwarmBlocker)
          .filter((item): item is CommandPlaneSwarmBlocker => item !== null)
      : [],
    recent_messages: Array.isArray(root.recent_messages)
      ? root.recent_messages
          .map(normalizeSwarmMessage)
          .filter((item): item is CommandPlaneSwarmMessage => item !== null)
      : [],
    recent_trace_events: Array.isArray(root.recent_trace_events)
      ? root.recent_trace_events
          .map(normalizeTrace)
          .filter((item): item is CommandPlaneTraceEvent => item !== null)
      : [],
    truth_notes: asStringArray(root.truth_notes),
  }
}

export function setCommandPlaneSurface(surface: CommandPlaneSurface): void {
  commandPlaneSurface.value = surface
}

export async function refreshCommandPlaneSnapshot(): Promise<void> {
  commandPlaneLoading.value = true
  commandPlaneError.value = null
  try {
    const raw = await fetchCommandPlaneSnapshot()
    commandPlaneSnapshot.value = normalizeSnapshot(raw)
  } catch (err) {
    commandPlaneError.value =
      err instanceof Error ? err.message : 'Failed to load command plane snapshot'
  } finally {
    commandPlaneLoading.value = false
  }
}

export async function refreshCommandPlaneHelp(): Promise<void> {
  commandPlaneHelpLoading.value = true
  commandPlaneHelpError.value = null
  try {
    const raw = await fetchCommandPlaneHelp()
    commandPlaneHelp.value = normalizeHelp(raw)
  } catch (err) {
    commandPlaneHelpError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane help'
  } finally {
    commandPlaneHelpLoading.value = false
  }
}

export async function refreshCommandPlaneSwarm(runId = currentSwarmRunId()): Promise<void> {
  commandPlaneSwarmLoading.value = true
  commandPlaneSwarmError.value = null
  try {
    const raw = await fetchCommandPlaneSwarm(runId)
    commandPlaneSwarm.value = normalizeSwarm(raw)
  } catch (err) {
    commandPlaneSwarmError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane swarm view'
  } finally {
    commandPlaneSwarmLoading.value = false
  }
}

async function runAction(key: string, path: string, body: Record<string, unknown>): Promise<void> {
  commandPlaneActionBusy.value = key
  commandPlaneActionError.value = null
  try {
    await runCommandPlaneAction(path, body)
    await refreshCommandPlaneSnapshot()
    await refreshCommandPlaneSwarm()
  } catch (err) {
    commandPlaneActionError.value =
      err instanceof Error ? err.message : 'Failed to execute command-plane action'
    throw err
  } finally {
    commandPlaneActionBusy.value = null
  }
}

export function pauseCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`pause:${operationId}`, '/api/v1/command-plane/operations/pause', {
    operation_id: operationId,
  })
}

export function resumeCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`resume:${operationId}`, '/api/v1/command-plane/operations/resume', {
    operation_id: operationId,
  })
}

export function recallCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`recall:${operationId}`, '/api/v1/command-plane/dispatch/recall', {
    operation_id: operationId,
  })
}

export function runCommandPlaneDispatchTick(
  filters: { operationId?: string; detachmentId?: string } = {},
): Promise<void> {
  return runAction('dispatch:tick', '/api/v1/command-plane/dispatch/tick', {
    ...(filters.operationId ? { operation_id: filters.operationId } : {}),
    ...(filters.detachmentId ? { detachment_id: filters.detachmentId } : {}),
  })
}

export function approveCommandPlaneDecision(decisionId: string): Promise<void> {
  return runAction(`approve:${decisionId}`, '/api/v1/command-plane/policy/approve', {
    decision_id: decisionId,
  })
}

export function denyCommandPlaneDecision(decisionId: string): Promise<void> {
  return runAction(`deny:${decisionId}`, '/api/v1/command-plane/policy/deny', {
    decision_id: decisionId,
  })
}

export function toggleCommandPlaneFreeze(unitId: string, enabled: boolean): Promise<void> {
  return runAction(`freeze:${unitId}`, '/api/v1/command-plane/policy/freeze', {
    unit_id: unitId,
    enabled,
  })
}

export function toggleCommandPlaneKillSwitch(unitId: string, enabled: boolean): Promise<void> {
  return runAction(`kill:${unitId}`, '/api/v1/command-plane/policy/kill-switch', {
    unit_id: unitId,
    enabled,
  })
}
