import { signal } from '@preact/signals'
import {
  fetchChainRun,
  fetchChainSummary,
  fetchCommandPlaneHelp,
  fetchCommandPlaneSnapshot,
  fetchCommandPlaneSummary,
  fetchCommandPlaneSwarm,
  runCommandPlaneAction,
} from './api'
import type {
  ChainHistoryEventSummary,
  ChainRuntimeStatus,
  CommandPlaneAlert,
  CommandPlaneAlertsResponse,
  CommandPlaneBudgetEnvelope,
  CommandPlaneChainConnection,
  CommandPlaneChainOverlay,
  CommandPlaneChainRecord,
  CommandPlaneChainRun,
  CommandPlaneChainRunNode,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
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
  CommandPlaneMicroarchSummary,
  CommandPlaneOperationsResponse,
  CommandPlanePolicyEnvelope,
  CommandPlaneSnapshot,
  CommandPlaneSummarySnapshot,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmProof,
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
import { registerCommandPlaneRefresh } from './store'

export const commandPlaneSummary = signal<CommandPlaneSummarySnapshot | null>(null)
export const commandPlaneSnapshot = signal<CommandPlaneSnapshot | null>(null)
export const commandPlaneLoading = signal(false)
export const commandPlaneDetailLoading = signal(false)
export const commandPlaneError = signal<string | null>(null)
export const commandPlaneDetailError = signal<string | null>(null)
export const commandPlaneActionBusy = signal<string | null>(null)
export const commandPlaneActionError = signal<string | null>(null)
export const commandPlaneSurface = signal<CommandPlaneSurface>('summary')
export const commandPlaneHelp = signal<CommandPlaneHelpResponse | null>(null)
export const commandPlaneHelpLoading = signal(false)
export const commandPlaneHelpError = signal<string | null>(null)
export const commandPlaneSwarm = signal<CommandPlaneSwarmResponse | null>(null)
export const commandPlaneSwarmLoading = signal(false)
export const commandPlaneSwarmError = signal<string | null>(null)
export const commandPlaneChainSummary = signal<CommandPlaneChainSummary | null>(null)
export const commandPlaneChainLoading = signal(false)
export const commandPlaneChainError = signal<string | null>(null)
export const commandPlaneChainRun = signal<CommandPlaneChainRunResponse | null>(null)
export const commandPlaneChainRunLoading = signal(false)
export const commandPlaneChainRunError = signal<string | null>(null)
export const commandPlaneChainFocusOperationId = signal<string | null>(null)
let activeChainRunRequestId: string | null = null

function surfaceNeedsDetail(surface: CommandPlaneSurface): boolean {
  return surface !== 'summary' && surface !== 'swarm'
}

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

function currentLocationParams(): URLSearchParams {
  if (typeof window === 'undefined') return new URLSearchParams()
  const search = new URLSearchParams(window.location.search)
  const hash = window.location.hash.replace(/^#/, '')
  const queryIdx = hash.indexOf('?')
  if (queryIdx >= 0) {
    const hashSearch = new URLSearchParams(hash.slice(queryIdx + 1))
    hashSearch.forEach((value, key) => {
      if (!search.has(key)) search.set(key, value)
    })
  }
  return search
}

function currentSwarmRunId(): string | undefined {
  const params = currentLocationParams()
  const value = params.get('run_id') ?? undefined
  return value && value.trim() !== '' ? value.trim() : undefined
}

function currentSwarmOperationId(): string | undefined {
  const params = currentLocationParams()
  const value = params.get('operation_id') ?? undefined
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

function normalizeChainRecord(raw: unknown): CommandPlaneChainRecord | null {
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
    chain: normalizeChainRecord(raw.chain),
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

function normalizeMicroarch(raw: unknown): CommandPlaneMicroarchSummary | undefined {
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
    microarch: normalizeMicroarch(root.microarch),
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

function normalizeSwarmProof(raw: unknown): CommandPlaneSwarmProof | undefined {
  if (!isRecord(raw)) return undefined
  const workers = isRecord(raw.workers) ? raw.workers : {}
  const pass = asBoolean(raw.pass)
  return {
    status: asString(raw.status) ?? 'missing',
    source: asString(raw.source) ?? 'none',
    run_id: asString(raw.run_id) ?? null,
    captured_at: asString(raw.captured_at) ?? null,
    ...(pass !== undefined ? { pass } : {}),
    ...(asNumber(raw.peak_hot_slots) != null ? { peak_hot_slots: asNumber(raw.peak_hot_slots) } : {}),
    ...(asNumber(raw.ctx_per_slot) != null ? { ctx_per_slot: asNumber(raw.ctx_per_slot) } : {}),
    workers: {
      expected: asNumber(workers.expected),
      joined: asNumber(workers.joined),
      current_task_bound: asNumber(workers.current_task_bound),
      fresh_heartbeats: asNumber(workers.fresh_heartbeats),
      done: asNumber(workers.done),
      final: asNumber(workers.final),
    },
    artifact_ref: asString(raw.artifact_ref) ?? null,
    missing_reason: asString(raw.missing_reason) ?? null,
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

function normalizeSummarySnapshot(raw: unknown): CommandPlaneSummarySnapshot {
  const root = isRecord(raw) ? raw : {}
  const topology = normalizeTopology(root.topology)
  const operations = normalizeOperations(root.operations)
  const detachments = normalizeDetachments(root.detachments)
  const alerts = normalizeAlerts(root.alerts)
  const decisions = normalizeDecisions(root.decisions)
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: {
      version: topology.version,
      generated_at: topology.generated_at,
      source: topology.source,
      summary: topology.summary,
    },
    operations: {
      version: operations.version,
      generated_at: operations.generated_at,
      summary: operations.summary,
      microarch: operations.microarch,
    },
    detachments: {
      version: detachments.version,
      generated_at: detachments.generated_at,
      summary: detachments.summary,
    },
    alerts: {
      version: alerts.version,
      generated_at: alerts.generated_at,
      summary: alerts.summary,
    },
    decisions: {
      version: decisions.version,
      generated_at: decisions.generated_at,
      summary: decisions.summary,
    },
    swarm_status: normalizeSwarmStatus(root.swarm_status),
    swarm_proof: normalizeSwarmProof(root.swarm_proof),
  }
}

function normalizeChainRuntime(raw: unknown): ChainRuntimeStatus | null {
  if (!isRecord(raw)) return null
  return {
    chain_id: asString(raw.chain_id) ?? null,
    started_at: asNumber(raw.started_at) ?? null,
    progress: asNumber(raw.progress) ?? null,
    elapsed_sec: asNumber(raw.elapsed_sec) ?? null,
  }
}

function normalizeChainHistoryEvent(raw: unknown): ChainHistoryEventSummary | null {
  if (!isRecord(raw)) return null
  const event = asString(raw.event)
  if (!event) return null
  return {
    event,
    chain_id: asString(raw.chain_id) ?? null,
    timestamp: asString(raw.timestamp) ?? null,
    duration_ms: asNumber(raw.duration_ms) ?? null,
    message: asString(raw.message) ?? null,
    tokens: asNumber(raw.tokens) ?? null,
  }
}

function normalizeChainOverlay(raw: unknown): CommandPlaneChainOverlay | null {
  if (!isRecord(raw)) return null
  const operation = normalizeOperationRecord(raw.operation)
  if (!operation) return null
  return {
    operation,
    runtime: normalizeChainRuntime(raw.runtime),
    history: normalizeChainHistoryEvent(raw.history),
    mermaid: asString(raw.mermaid) ?? null,
    preview_run: normalizeChainRun(raw.preview_run),
  }
}

function normalizeChainConnection(raw: unknown): CommandPlaneChainConnection {
  const root = isRecord(raw) ? raw : {}
  return {
    status: asString(root.status) ?? 'disconnected',
    base_url: asString(root.base_url) ?? null,
    message: asString(root.message) ?? null,
  }
}

function normalizeChainSummary(raw: unknown): CommandPlaneChainSummary {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    connection: normalizeChainConnection(root.connection),
    summary: summary
      ? {
          linked_operations: asNumber(summary.linked_operations),
          active_chains: asNumber(summary.active_chains),
          running_operations: asNumber(summary.running_operations),
          recent_failures: asNumber(summary.recent_failures),
          last_history_event_at: asString(summary.last_history_event_at) ?? null,
        }
      : undefined,
    operations: Array.isArray(root.operations)
      ? root.operations
          .map(normalizeChainOverlay)
          .filter((item): item is CommandPlaneChainOverlay => item !== null)
      : [],
    recent_history: Array.isArray(root.recent_history)
      ? root.recent_history
          .map(normalizeChainHistoryEvent)
          .filter((item): item is ChainHistoryEventSummary => item !== null)
      : [],
  }
}

function normalizeChainRunNode(raw: unknown): CommandPlaneChainRunNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  if (!id) return null
  return {
    id,
    type: asString(raw.type),
    status: asString(raw.status),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    error: asString(raw.error) ?? null,
  }
}

function normalizeChainRun(raw: unknown): CommandPlaneChainRun | null {
  if (!isRecord(raw)) return null
  const runId = asString(raw.run_id)
  const chainId = asString(raw.chain_id)
  if (!chainId) return null
  return {
    run_id: runId ?? null,
    chain_id: chainId,
    duration_ms: asNumber(raw.duration_ms),
    success: asBoolean(raw.success),
    mermaid: asString(raw.mermaid),
    nodes: Array.isArray(raw.nodes)
      ? raw.nodes
          .map(normalizeChainRunNode)
          .filter((item): item is CommandPlaneChainRunNode => item !== null)
      : [],
  }
}

function normalizeChainRunResponse(raw: unknown): CommandPlaneChainRunResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    run: normalizeChainRun(root.run),
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
    provider_base_url: asString(raw.provider_base_url) ?? null,
    provider_reachable: asBoolean(raw.provider_reachable) ?? null,
    provider_status_code: asNumber(raw.provider_status_code) ?? null,
    provider_model_id: asString(raw.provider_model_id) ?? null,
    actual_model_id: asString(raw.actual_model_id) ?? null,
    expected_slots: asNumber(raw.expected_slots),
    actual_slots: asNumber(raw.actual_slots),
    expected_ctx: asNumber(raw.expected_ctx),
    actual_ctx: asNumber(raw.actual_ctx),
    slot_reachable: asBoolean(raw.slot_reachable) ?? null,
    slot_status_code: asNumber(raw.slot_status_code) ?? null,
    runtime_blocker: asString(raw.runtime_blocker) ?? null,
    detail: asString(raw.detail) ?? null,
    checked_at: asString(raw.checked_at) ?? null,
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
  if (surfaceNeedsDetail(surface)) {
    void ensureCommandPlaneDetail()
  }
}

export async function refreshCommandPlaneSummary(): Promise<void> {
  commandPlaneLoading.value = true
  commandPlaneError.value = null
  try {
    const raw = await fetchCommandPlaneSummary()
    commandPlaneSummary.value = normalizeSummarySnapshot(raw)
  } catch (err) {
    commandPlaneError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane summary'
  } finally {
    commandPlaneLoading.value = false
  }
}

export function focusCommandPlaneChainOperation(operationId: string | null): void {
  commandPlaneChainFocusOperationId.value = operationId
}

export async function refreshCommandPlaneSnapshot(): Promise<void> {
  commandPlaneDetailLoading.value = true
  commandPlaneDetailError.value = null
  try {
    const raw = await fetchCommandPlaneSnapshot()
    commandPlaneSnapshot.value = normalizeSnapshot(raw)
  } catch (err) {
    commandPlaneDetailError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane snapshot'
  } finally {
    commandPlaneDetailLoading.value = false
  }
}

export async function ensureCommandPlaneDetail(): Promise<void> {
  if (commandPlaneSnapshot.value || commandPlaneDetailLoading.value) return
  await refreshCommandPlaneSnapshot()
}

export async function refreshCommandPlaneCurrentSurface(): Promise<void> {
  await refreshCommandPlaneSummary()
  if (surfaceNeedsDetail(commandPlaneSurface.value)) {
    await refreshCommandPlaneSnapshot()
  }
}

export async function refreshCommandPlaneChainSummary(): Promise<void> {
  commandPlaneChainLoading.value = true
  commandPlaneChainError.value = null
  try {
    const raw = await fetchChainSummary()
    const normalized = normalizeChainSummary(raw)
    commandPlaneChainSummary.value = normalized
    const focused = commandPlaneChainFocusOperationId.value
    if (normalized.operations.length === 0) {
      commandPlaneChainFocusOperationId.value = null
    } else if (!focused || !normalized.operations.some(item => item.operation.operation_id === focused)) {
      commandPlaneChainFocusOperationId.value = normalized.operations[0]?.operation.operation_id ?? null
    }
  } catch (err) {
    commandPlaneChainError.value =
      err instanceof Error ? err.message : 'Failed to load chain summary'
  } finally {
    commandPlaneChainLoading.value = false
  }
}

export function clearCommandPlaneChainRun(): void {
  activeChainRunRequestId = null
  commandPlaneChainRun.value = null
  commandPlaneChainRunLoading.value = false
  commandPlaneChainRunError.value = null
}

export async function loadCommandPlaneChainRun(runId: string): Promise<void> {
  activeChainRunRequestId = runId
  commandPlaneChainRunLoading.value = true
  commandPlaneChainRunError.value = null
  try {
    const raw = await fetchChainRun(runId)
    if (activeChainRunRequestId !== runId) return
    commandPlaneChainRun.value = normalizeChainRunResponse(raw)
  } catch (err) {
    if (activeChainRunRequestId !== runId) return
    commandPlaneChainRun.value = null
    commandPlaneChainRunError.value =
      err instanceof Error ? err.message : 'Failed to load chain run'
  } finally {
    if (activeChainRunRequestId === runId) {
      commandPlaneChainRunLoading.value = false
    }
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

export async function refreshCommandPlaneSwarm(
  runId = currentSwarmRunId(),
  operationId = currentSwarmOperationId(),
): Promise<void> {
  commandPlaneSwarmLoading.value = true
  commandPlaneSwarmError.value = null
  try {
    const raw = await fetchCommandPlaneSwarm(runId, operationId)
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
    await refreshCommandPlaneSummary()
    if (commandPlaneSnapshot.value || surfaceNeedsDetail(commandPlaneSurface.value)) {
      await refreshCommandPlaneSnapshot()
    }
    await refreshCommandPlaneSwarm()
    await refreshCommandPlaneChainSummary()
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

registerCommandPlaneRefresh(() => {
  void refreshCommandPlaneCurrentSurface()
  void refreshCommandPlaneChainSummary()
  if (commandPlaneSurface.value === 'swarm' || commandPlaneSwarm.value !== null) {
    void refreshCommandPlaneSwarm()
  }
})
