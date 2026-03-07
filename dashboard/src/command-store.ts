import { signal } from '@preact/signals'
import { fetchCommandPlaneSnapshot, runCommandPlaneAction } from './api'
import type {
  CommandPlaneAlert,
  CommandPlaneAlertsResponse,
  CommandPlaneBudgetEnvelope,
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
    source: asString(raw.source),
    status: asString(raw.status),
    last_event_at: asString(raw.last_event_at) ?? null,
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

async function runAction(key: string, path: string, body: Record<string, unknown>): Promise<void> {
  commandPlaneActionBusy.value = key
  commandPlaneActionError.value = null
  try {
    await runCommandPlaneAction(path, body)
    await refreshCommandPlaneSnapshot()
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
