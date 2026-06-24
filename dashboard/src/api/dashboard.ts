// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { isRecord, asBoolean, asInt, asNullableString, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { normalizeKeeperTrustTerminalReason } from '../keeper-store-normalize'
import { get, post, type AbortableRequestOptions } from './core'
import {
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from './schemas/agent-timeline'
import { type LogEntry, type LogsResponse } from './schemas/logs'
import {
  type RuntimeDefaultsResponse,
  type RuntimeEntry,
  type KeeperAssignment,
  type ModelRouting,
} from './schemas/runtime-defaults'
import {
  type ProviderLogCatalogEntry,
  type ProviderLogsCatalogResponse,
  type ProviderLogTailLine,
  type ProviderLogTailResponse,
} from './schemas/provider-logs'
import type {
  DashboardGoalsTreeResponse,
  DashboardGoalDetailResponse,
  GoalDetailKeeper,
  GoalKeeperTrustApprovalState,
  GoalKeeperTrustExecutionSummary,
  GoalKeeperTrustLatestEvent,
  GoalKeeperTrustSummary,
  GoalDetailTimelineEvent,
  GoalAttainmentProjection,
  GoalCompletionSummary,
  GoalTaskSummary,
  GoalTreeNode,
  GoalTreeSummary,
  GoalTreeTask,
  GoalVerificationRequest,
  GoalVerificationSummary,
  GoalVerificationVote,
} from '../types'
export { DashboardConfigSchemaDriftError } from './schemas/dashboard-config'
export type {
  ConfigEntry,
  ConfigEntryProvenance,
  ConfigEntrySource,
  DashboardConfigResponse,
} from './schemas/dashboard-config'
export { reportToolHostFailure } from './tool-host-failure'
export { fetchDashboardBootstrap, fetchDashboardShell } from './dashboard-hot'
export type { FusionRunStatusLabel, FusionRunRecord, DashboardFusionRunsResponse } from './dashboard-fusion'
export { parseFusionRunsResponse, fetchFusionRuns } from './dashboard-fusion'

// --- Dashboard projections ---

export type { DashboardFeedRetention, DashboardFeedMetadata } from './dashboard-shared'
export { decodeDashboardFeedMetadata } from './dashboard-shared'

// --- System logs ---

export type { LogEntry, LogsResponse }
export { LogsSchemaDriftError } from './schemas/logs'
export { RuntimeDefaultsSchemaDriftError } from './schemas/runtime-defaults'
export type { RuntimeDefaultsResponse, RuntimeEntry, KeeperAssignment, ModelRouting }
export type {
  ProviderLogCatalogEntry,
  ProviderLogsCatalogResponse,
  ProviderLogTailLine,
  ProviderLogTailResponse,
}
export { ProviderLogsSchemaDriftError } from './schemas/provider-logs'

export {
  fetchLogs,
  fetchProviderLogsCatalog,
  fetchProviderLogTail,
  fetchDashboardConfig,
  parseContextThresholds,
} from './dashboard-logs'

export type { AgentTimelineEvent, AgentTimelineResponse }
export { AgentTimelineSchemaDriftError } from './schemas/agent-timeline'

export { fetchAgentTimeline } from './dashboard-agent'

export type {
  AgentRelation,
  AgentRelationsResponse,
} from './schemas/agent-relations'
export { AgentRelationsSchemaDriftError } from './schemas/agent-relations'
export { fetchAgentRelations } from './dashboard-agent'

// Re-export from the hot-path API barrel where the SSOT definition lives
// alongside `fetchDashboardShell` / `fetchDashboardBootstrap` (all three
// share the same hot/bootstrap consumer profile). Until 2026-05-27 the
// implementation was duplicated here verbatim, with `namespace-truth-actions`
// importing the hot variant and `telemetry-unified` / `fleet-telemetry-panel`
// the dashboard.ts variant — same endpoint, same timeout, two definitions
// that could drift independently. SSOT now lives in `./dashboard-hot`.
export { fetchDashboardNamespaceTruth } from './dashboard-hot'

export type {
  DashboardExecutionTrustKeeper,
  DashboardExecutionTrustResponse,
  ToolQualityHourlyPoint,
  ToolQualityResponse,
  DashboardPerfRow,
  DashboardPerfComparisonRow,
  DashboardPerfResponse,
} from './dashboard-execution'
export {
  fetchDashboardExecution,
  fetchDashboardExecutionTrust,
  fetchToolQuality,
  fetchDashboardPerf,
  fetchDashboardMemory,
} from './dashboard-execution'

export type { DashboardScheduleDecision, DashboardScheduleResolveResponse } from './dashboard-governance'
export {
  fetchDashboardGovernance,
  resolveGovernanceApproval,
  deleteGovernanceApprovalRule,
  resolveScheduleApproval,
  fetchGovernanceCaseStatus,
  submitGovernancePetition,
  submitGovernanceCaseBrief,
  decideGovernanceExecutionOrder,
} from './dashboard-governance'
export { fetchDashboardBriefing, fetchDashboardMission, fetchDashboardMissionSession } from './dashboard-mission'

export type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeAssignment,
  DashboardRuntimeAssignmentGovernance,
  DashboardRuntimeProvidersResponse,
  BucketMetric,
  DashboardRuntimeModelMetric,
  LatencyBucket,
  DashboardRuntimeModelMetricsResponse,
  RuntimeTomlConfig,
} from './dashboard-runtime'
export {
  fetchRuntimeProviders,
  fetchRuntimeModelMetrics,
  fetchRuntimeTomlConfig,
  fetchRuntimeDefaults,
  saveRuntimeTomlConfig,
} from './dashboard-runtime'

export type {
  KeeperCostMetric,
  KeeperCostMetricsResponse,
  KeeperDecision,
  KeeperDecisionContext,
  KeeperDecisionsResponse,
  CostPerAgentRow,
  CostMatrix,
  CostLatencyBucket,
  CostLatencyResponse,
} from './dashboard-keeper-cost'
export {
  fetchKeeperCostMetrics,
  fetchKeeperDecisions,
  fetchCostLatency,
} from './dashboard-keeper-cost'

export { fetchDashboardMissionBriefing, fetchDashboardPlanning } from './dashboard-mission'

function decodeGoalVerificationPrincipal(
  raw: unknown,
): GoalVerificationRequest['requested_by'] | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  if (!id) return null
  return {
    id,
    display_name: asNullableString(raw.display_name),
  }
}

function decodeGoalVerificationPolicySnapshot(
  raw: unknown,
): GoalVerificationRequest['policy_snapshot'] | null {
  if (!isRecord(raw)) return null
  const principals = asRecordArray(raw.principals)
    .map(decodeGoalVerificationPrincipal)
    .filter(
      (
        principal,
      ): principal is NonNullable<GoalVerificationRequest['policy_snapshot']>['principals'][number] =>
        principal !== null,
    )
  const eligiblePrincipals = asRecordArray(raw.eligible_principals)
    .map(decodeGoalVerificationPrincipal)
    .filter(
      (
        principal,
      ): principal is NonNullable<GoalVerificationRequest['policy_snapshot']>['eligible_principals'][number] =>
        principal !== null,
    )
  return {
    principals,
    eligible_principals: eligiblePrincipals,
    required_verdicts: asInt(raw.required_verdicts) ?? 0,
  }
}

function decodeGoalVerificationVote(raw: unknown): GoalVerificationVote | null {
  if (!isRecord(raw)) return null
  const principal = decodeGoalVerificationPrincipal(raw.principal)
  const decision = asString(raw.decision)
  const submittedAt = asString(raw.submitted_at)
  if (!principal || !decision || !submittedAt) return null
  return {
    principal,
    decision,
    note: asNullableString(raw.note),
    evidence_refs: asStringArray(raw.evidence_refs),
    submitted_at: submittedAt,
  }
}

function decodeGoalVerificationRequest(raw: unknown): GoalVerificationRequest | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const goalId = asString(raw.goal_id)
  const targetPhase = asString(raw.target_phase)
  const requestedBy = decodeGoalVerificationPrincipal(raw.requested_by)
  const policySnapshot = decodeGoalVerificationPolicySnapshot(raw.policy_snapshot)
  const status = asString(raw.status)
  const createdAt = asString(raw.created_at)
  if (!id || !goalId || !targetPhase || !requestedBy || !policySnapshot || !status || !createdAt) {
    return null
  }
  return {
    id,
    goal_id: goalId,
    target_phase: targetPhase,
    requested_by: requestedBy,
    policy_snapshot: policySnapshot,
    votes: asRecordArray(raw.votes)
      .map(decodeGoalVerificationVote)
      .filter((vote): vote is GoalVerificationVote => vote !== null),
    status,
    created_at: createdAt,
    resolved_at: asNullableString(raw.resolved_at),
  }
}

function decodeGoalVerificationSummary(raw: unknown): GoalVerificationSummary {
  if (!isRecord(raw)) {
    return {
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    }
  }
  return {
    effective_policy: decodeGoalVerificationPolicySnapshot(raw.effective_policy),
    open_request: decodeGoalVerificationRequest(raw.open_request),
    latest_request: decodeGoalVerificationRequest(raw.latest_request),
    approve_count: asInt(raw.approve_count) ?? 0,
    reject_count: asInt(raw.reject_count) ?? 0,
    remaining_possible: asInt(raw.remaining_possible) ?? 0,
  }
}

function decodeGoalTreeTask(raw: unknown): GoalTreeTask | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  if (!id || !title) return null
  return {
    id,
    title,
    status: asString(raw.status, 'unknown'),
    status_color: asString(raw.status_color, ''),
    priority: asInt(raw.priority) ?? 0,
    assignee: asNullableString(raw.assignee),
    goal_id: asNullableString(raw.goal_id),
    linkage_source: asString(raw.linkage_source, 'none'),
    is_terminal: asBoolean(raw.is_terminal, false),
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalFsmProjection(raw: unknown, phase: string) {
  if (!isRecord(raw)) {
    return {
      state: phase,
      source: 'goal.phase',
      state_kind: phase,
      next_actions: [],
      activity_observation: 'goal_metadata',
      stagnation_status: 'recent',
    }
  }
  return {
    state: asString(raw.state, phase),
    source: asString(raw.source, 'goal.phase'),
    state_kind: asString(raw.state_kind, phase),
    next_actions: asStringArray(raw.next_actions),
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    stagnation_status: asString(raw.stagnation_status, 'recent'),
  }
}

function decodeGoalKeeperTrustLatestEvent(raw: unknown): GoalKeeperTrustLatestEvent | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const ts = asString(raw.ts)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const severity = asString(raw.severity)
  if (!kind || !ts || !title || !summary || !severity) return null
  return {
    kind,
    ts,
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_turn_id: asInt(raw.keeper_turn_id) ?? null,
    task_id: asNullableString(raw.task_id),
    goal_ids: asStringArray(raw.goal_ids),
    title,
    summary,
    severity,
    next_human_action: asNullableString(raw.next_human_action),
    trace_id: asNullableString(raw.trace_id),
  }
}

function decodeGoalKeeperTrustApprovalState(raw: unknown): GoalKeeperTrustApprovalState | null {
  if (!isRecord(raw)) return null
  const pendingFirst = isRecord(raw.pending_first) ? raw.pending_first : null
  return {
    state: asNullableString(raw.state),
    summary: asNullableString(raw.summary),
    pending_count: asInt(raw.pending_count) ?? null,
    pending_first: pendingFirst
      ? {
          id: asNullableString(pendingFirst.id),
          tool_name: asNullableString(pendingFirst.tool_name),
          task_id: asNullableString(pendingFirst.task_id),
          blocker_class: asNullableString(pendingFirst.blocker_class),
        }
      : null,
    latest_event_at: asNullableString(raw.latest_event_at),
  }
}

function decodeGoalKeeperTrustExecutionSummary(raw: unknown): GoalKeeperTrustExecutionSummary | null {
  if (!isRecord(raw)) return null
  return {
    provider_attempt_count: asInt(raw.provider_attempt_count) ?? null,
    provider_fallback_applied:
      typeof raw.provider_fallback_applied === 'boolean'
        ? raw.provider_fallback_applied
        : null,
    provider_selected_model: asNullableString(raw.provider_selected_model),
    runtime_outcome: asNullableString(raw.runtime_outcome),
    sandbox_summary: asNullableString(raw.sandbox_summary),
    sandbox_root: asNullableString(raw.sandbox_root),
    mutation_guard_summary: asNullableString(raw.mutation_guard_summary),
    latest_receipt_at: asNullableString(raw.latest_receipt_at),
  }
}

function decodeGoalKeeperTrustSummary(raw: unknown): GoalKeeperTrustSummary | null {
  if (!isRecord(raw)) return null
  return {
    disposition: asNullableString(raw.disposition),
    disposition_reason: asNullableString(raw.disposition_reason),
    operator_disposition: asNullableString(raw.operator_disposition),
    operator_disposition_reason: asNullableString(raw.operator_disposition_reason),
    needs_attention:
      typeof raw.needs_attention === 'boolean'
        ? raw.needs_attention
        : null,
    attention_reason: asNullableString(raw.attention_reason),
    next_human_action: asNullableString(raw.next_human_action),
    latest_terminal_reason: normalizeKeeperTrustTerminalReason(raw.latest_terminal_reason),
    latest_next_action: asNullableString(raw.latest_next_action),
    approval_state: decodeGoalKeeperTrustApprovalState(raw.approval_state ?? raw.approval),
    execution_summary:
      decodeGoalKeeperTrustExecutionSummary(raw.execution_summary ?? raw.execution),
    latest_causal_event: decodeGoalKeeperTrustLatestEvent(raw.latest_causal_event),
  }
}

function decodeGoalAttainmentProjection(
  raw: unknown,
  fallback: {
    metric: string | null
    targetValue: string | null
    taskDoneCount: number
    taskCount: number
  },
): GoalAttainmentProjection {
  if (!isRecord(raw)) {
    return {
      state: 'unmeasured',
      basis: 'unmeasured',
      metric: fallback.metric,
      target_value: fallback.targetValue,
      target_parse_status: fallback.targetValue ? 'unparseable' : 'absent',
      unit: 'unknown',
      observed_value: null,
      target_numeric: null,
      attainment_pct: null,
      task_done_count: fallback.taskDoneCount,
      task_count: fallback.taskCount,
      note: 'Attainment projection missing from payload.',
    }
  }
  return {
    state: asString(raw.state, 'unmeasured'),
    basis: asString(raw.basis, 'unmeasured'),
    metric: asNullableString(raw.metric) ?? fallback.metric,
    target_value: asNullableString(raw.target_value) ?? fallback.targetValue,
    target_parse_status: asString(raw.target_parse_status, 'absent'),
    unit: asString(raw.unit, 'unknown'),
    observed_value: asNumber(raw.observed_value) ?? null,
    target_numeric: asNumber(raw.target_numeric) ?? null,
    attainment_pct: asInt(raw.attainment_pct) ?? null,
    task_done_count: asInt(raw.task_done_count) ?? fallback.taskDoneCount,
    task_count: asInt(raw.task_count) ?? fallback.taskCount,
    note: asString(raw.note, ''),
  }
}

function decodeNumberRecord(raw: unknown): Record<string, number> {
  if (!isRecord(raw)) return {}
  const out: Record<string, number> = {}
  for (const [key, value] of Object.entries(raw)) {
    const count = asInt(value)
    if (count != null) out[key] = count
  }
  return out
}

function decodeGoalTaskSummary(
  raw: unknown,
  fallback: { taskCount: number; taskDoneCount: number; tasks: GoalTreeTask[] },
): GoalTaskSummary | undefined {
  if (!isRecord(raw)) return undefined
  const terminal = asInt(raw.terminal) ?? fallback.tasks.filter(task => task.is_terminal).length
  return {
    total: asInt(raw.total) ?? fallback.taskCount,
    done: asInt(raw.done) ?? fallback.taskDoneCount,
    open: asInt(raw.open) ?? Math.max(0, fallback.taskCount - terminal),
    terminal,
    awaiting_verification: asInt(raw.awaiting_verification) ?? 0,
    cancelled: asInt(raw.cancelled) ?? 0,
    unassigned: asInt(raw.unassigned) ?? 0,
    completion_pct: asInt(raw.completion_pct) ?? null,
    by_status: decodeNumberRecord(raw.by_status),
    by_linkage_source: decodeNumberRecord(raw.by_linkage_source),
  }
}

function decodeGoalCompletionSummary(raw: unknown): GoalCompletionSummary | undefined {
  if (!isRecord(raw)) return undefined
  return {
    state: asString(raw.state, 'unmeasured'),
    pct: asInt(raw.pct) ?? null,
    pct_source: asString(raw.pct_source, 'none'),
    attainment_state: asString(raw.attainment_state, 'unmeasured'),
    attainment_basis: asString(raw.attainment_basis, 'unmeasured'),
    task_total: asInt(raw.task_total) ?? 0,
    task_done: asInt(raw.task_done) ?? 0,
    task_open: asInt(raw.task_open) ?? 0,
    is_complete: asBoolean(raw.is_complete) ?? false,
    is_terminal: asBoolean(raw.is_terminal) ?? false,
    ready_to_request_completion: asBoolean(raw.ready_to_request_completion) ?? false,
    gate: asString(raw.gate, 'none'),
    requires_verifier: asBoolean(raw.requires_verifier) ?? false,
    requires_completion_approval: asBoolean(raw.requires_completion_approval) ?? false,
    active_verification_request: asBoolean(raw.active_verification_request) ?? false,
    blocking_source: asString(raw.blocking_source, 'none'),
    blocking_reason: asString(raw.blocking_reason, ''),
  }
}

function decodeGoalTreeNode(raw: unknown): GoalTreeNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  if (!id || !title) return null
  const tasks = asRecordArray(raw.tasks)
    .map(decodeGoalTreeTask)
    .filter((task): task is GoalTreeTask => task !== null)
  const children = asRecordArray(raw.children)
    .map(decodeGoalTreeNode)
    .filter((node): node is GoalTreeNode => node !== null)
  const metric = asNullableString(raw.metric)
  const targetValue = asNullableString(raw.target_value)
  const taskCount = asInt(raw.task_count) ?? tasks.length
  const taskDoneCount = asInt(raw.task_done_count) ?? 0
  const attainment = decodeGoalAttainmentProjection(raw.attainment, {
    metric,
    targetValue,
    taskDoneCount,
    taskCount,
  })
  const verificationSummary = decodeGoalVerificationSummary(raw.verification_summary)
  return {
    id,
    title,
    horizon: asString(raw.horizon, 'unknown'),
    status: asString(raw.status, 'unknown'),
    status_color: asString(raw.status_color, ''),
    phase: asString(raw.phase, 'unknown'),
    phase_color: asString(raw.phase_color, ''),
    goal_fsm: decodeGoalFsmProjection(raw.goal_fsm, asString(raw.phase, 'unknown')),
    health: asString(raw.health, 'at_risk'),
    health_color: asString(raw.health_color, ''),
    badges: asStringArray(raw.badges),
    status_reason: asString(raw.status_reason, ''),
    priority: asInt(raw.priority) ?? 0,
    metric,
    target_value: targetValue,
    require_completion_approval: asBoolean(raw.require_completion_approval) ?? false,
    due_date: asNullableString(raw.due_date),
    parent_goal_id: asNullableString(raw.parent_goal_id),
    convergence: asNumber(raw.convergence, 0),
    convergence_pct: asInt(raw.convergence_pct) ?? 0,
    attainment,
    tasks,
    task_count: taskCount,
    task_done_count: taskDoneCount,
    task_summary: decodeGoalTaskSummary(raw.task_summary, {
      taskCount,
      taskDoneCount,
      tasks,
    }),
    completion_summary: decodeGoalCompletionSummary(raw.completion_summary),
    verification_summary: verificationSummary,
    effective_verifier_policy: decodeGoalVerificationPolicySnapshot(raw.effective_verifier_policy),
    active_verification_request: decodeGoalVerificationRequest(raw.active_verification_request),
    pending_verification_count: asInt(raw.pending_verification_count) ?? 0,
    timeline_events: Array.isArray(raw.timeline_events) ? raw.timeline_events : [],
    children,
    child_count: asInt(raw.child_count) ?? children.length,
    last_activity_at: asString(raw.last_activity_at, ''),
    stagnation_seconds: asInt(raw.stagnation_seconds) ?? 0,
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    stagnation_status: asString(raw.stagnation_status, 'recent'),
    linked_keeper_names: asStringArray(raw.linked_keeper_names),
    pending_approval_count: asInt(raw.pending_approval_count) ?? 0,
    infra_risk_count: asInt(raw.infra_risk_count) ?? 0,
    linkage_source: asString(raw.linkage_source, 'none'),
    linkage_warning_count: asInt(raw.linkage_warning_count) ?? 0,
    blocking_source: asString(raw.blocking_source, 'none'),
    blocking_reason: asString(raw.blocking_reason, ''),
    latest_keeper_ref: asNullableString(raw.latest_keeper_ref),
    latest_turn_ref: asInt(raw.latest_turn_ref) ?? null,
    stalled_since: asNullableString(raw.stalled_since),
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalTreeSummary(raw: unknown): GoalTreeSummary {
  if (!isRecord(raw)) {
    return {
      total_goals: 0,
      active_goals: 0,
      done_goals: 0,
      on_track_goals: 0,
      paused_goals: 0,
      at_risk_goals: 0,
      blocked_goals: 0,
      total_tasks: 0,
      done_tasks: 0,
      pending_approvals: 0,
      infra_risk_count: 0,
      overall_convergence: 0,
      overall_convergence_pct: 0,
    }
  }
  return {
    total_goals: asInt(raw.total_goals) ?? 0,
    active_goals: asInt(raw.active_goals) ?? 0,
    on_track_goals: asInt(raw.on_track_goals) ?? 0,
    done_goals: asInt(raw.done_goals) ?? 0,
    paused_goals: asInt(raw.paused_goals) ?? 0,
    at_risk_goals: asInt(raw.at_risk_goals) ?? 0,
    blocked_goals: asInt(raw.blocked_goals) ?? 0,
    total_tasks: asInt(raw.total_tasks) ?? 0,
    done_tasks: asInt(raw.done_tasks) ?? 0,
    pending_approvals: asInt(raw.pending_approvals) ?? 0,
    infra_risk_count: asInt(raw.infra_risk_count) ?? 0,
    overall_convergence: asNumber(raw.overall_convergence, 0),
    overall_convergence_pct: asInt(raw.overall_convergence_pct) ?? 0,
  }
}

function decodeGoalDetailKeeper(raw: unknown): GoalDetailKeeper | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const agentName = asString(raw.agent_name)
  const sandboxProfile = asString(raw.sandbox_profile)
  const networkMode = asString(raw.network_mode)
  const runtimeName = asString(raw.runtime_id)
  if (!name || !agentName || !sandboxProfile || !networkMode || !runtimeName) return null
  return {
    name,
    agent_name: agentName,
    current_task_id: asNullableString(raw.current_task_id),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    sandbox_profile: sandboxProfile,
    network_mode: networkMode,
    runtime_id: runtimeName,
    runtime_outcome: asNullableString(raw.runtime_outcome),
    latest_execution_outcome: asNullableString(raw.latest_execution_outcome),
    latest_execution_at: asNullableString(raw.latest_execution_at),
    latest_receipt: isRecord(raw.latest_receipt) ? raw.latest_receipt : null,
    runtime_trust: decodeGoalKeeperTrustSummary(raw.runtime_trust),
    latest_causal_event: decodeGoalKeeperTrustLatestEvent(raw.latest_causal_event),
  }
}

function decodeGoalDetailTimelineEvent(raw: unknown): GoalDetailTimelineEvent | null {
  if (!isRecord(raw)) return null
  const ts = asString(raw.ts)
  const kind = asString(raw.kind)
  const lane = asString(raw.lane)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const severity = asString(raw.severity)
  if (!ts || !kind || !lane || !title || !summary || !severity) return null
  return {
    ts,
    kind,
    lane,
    title,
    summary,
    severity,
  }
}

function decodeDashboardGoalsTreeResponse(raw: unknown): DashboardGoalsTreeResponse | null {
  if (!isRecord(raw)) return null
  const tree = asRecordArray(raw.tree)
    .map(decodeGoalTreeNode)
    .filter((node): node is GoalTreeNode => node !== null)
  const summary = decodeGoalTreeSummary(raw.summary)
  const generatedAt = asString(raw.generated_at)
  return generatedAt
    ? { generated_at: generatedAt, tree, summary }
    : { tree, summary }
}

function decodeDashboardGoalDetailResponse(raw: unknown): DashboardGoalDetailResponse | null {
  if (!isRecord(raw)) return null
  const goal = decodeGoalTreeNode(raw.goal)
  if (!goal) return null
  const generatedAt = asString(raw.generated_at)
  const decoded: DashboardGoalDetailResponse = {
    goal,
    linked_tasks: asRecordArray(raw.linked_tasks)
      .map(decodeGoalTreeTask)
      .filter((task): task is GoalTreeTask => task !== null),
    linked_keepers: asRecordArray(raw.linked_keepers)
      .map(decodeGoalDetailKeeper)
      .filter((keeper): keeper is GoalDetailKeeper => keeper !== null),
    approvals: asRecordArray(raw.approvals),
    execution_receipts: asRecordArray(raw.execution_receipts),
    timeline: asRecordArray(raw.timeline)
      .map(decodeGoalDetailTimelineEvent)
      .filter((event): event is GoalDetailTimelineEvent => event !== null),
  }
  return generatedAt ? { ...decoded, generated_at: generatedAt } : decoded
}

export async function fetchDashboardGoalsTree(): Promise<DashboardGoalsTreeResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/goals')
  const decoded = decodeDashboardGoalsTreeResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goals payload')
  return decoded
}

export async function fetchDashboardGoalDetail(goalId: string): Promise<DashboardGoalDetailResponse> {
  const raw = await get<unknown>(`/api/v1/dashboard/goals/detail?goal_id=${encodeURIComponent(goalId)}`)
  const decoded = decodeDashboardGoalDetailResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goal detail payload')
  return decoded
}

export type {
  DashboardToolInventoryItem,
  ToolMetricsTopEntry,
  ToolMetricsResponse,
  DashboardScheduledAutomationFsm,
  DashboardScheduledAutomationExecution,
  DashboardScheduledAutomationKeeperToolStatus,
  DashboardScheduledAutomationActor,
  DashboardScheduledAutomationSignal,
  DashboardScheduledAutomationRequest,
  DashboardScheduledAutomationPayloadSupport,
  DashboardScheduledAutomation,
  DashboardToolsResponse,
} from './dashboard-tools-prompts'

export type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeResolution,
  ServerBuildIdentity as DashboardBuildIdentity,
} from '../types'
export type {
  KeeperRuntimeResolved,
  KeeperRuntimeField,
  KeeperRuntimeSource,
} from '../types'

export type {
  DashboardRuntimeProviderProbe,
  DashboardRuntimeProviderProbeSummary,
  DashboardRuntimeProbePayload,
  DashboardRuntimeProbeResponse,
  PromptSource,
  DashboardPromptItem,
} from './dashboard-tools-prompts'
export {
  fetchToolMetrics,
  fetchDashboardRuntimeProbe,
  fetchDashboardTools,
  fetchDashboardPrompts,
  savePromptOverride,
  clearPromptOverride,
} from './dashboard-tools-prompts'

export type {
  SandboxProfile,
  SandboxNetworkMode,
  SharedMemoryScope,
  KeeperConfigUpdatePayload,
} from './dashboard-keeper-config'
export {
  fetchKeeperConfig,
  patchKeeperConfig,
  setKeeperToolPolicy,
} from './dashboard-keeper-config'

export type { TrajectoryEntry, TrajectoryResponse } from './dashboard-keeper-trajectory'
export { fetchKeeperTrajectory } from './dashboard-keeper-trajectory'

// ── Keeper tool stats (server-side aggregation) ──────────
export type { TelemetryFreshnessMetadata, DashboardSurfaceEnvelope, TelemetryCoverageGap } from './dashboard-shared'
export { decodeTelemetryFreshnessMetadata } from './dashboard-shared'
export type { ToolStat, HourlyBucket, ToolStatsResponse } from './dashboard-keeper-tool-stats'
export { fetchKeeperToolStats } from './dashboard-keeper-tool-stats'

// ── Keeper tool call log (full I/O) ──────────────────────
export type { ToolCallOutputBlob, ToolCallEntry, ToolCallsResponse } from './dashboard-keeper-tool-calls'
export { fetchKeeperToolCalls } from './dashboard-keeper-tool-calls'

// ── Keeper turn records (RFC-0233 PR-4) ─────────────────

export type {
  TurnBlock,
  TurnRecordEntry,
  TurnBlockDiff,
  TurnRecordRow,
  MemoryOsEpisodeSummary,
  MemoryOsTurnRecordSnapshot,
  KeeperUserModelItem,
  KeeperUserModelSnapshot,
  TurnRecordsResponse,
  TurnTranscriptLine,
  TurnTranscript,
} from './dashboard-turn-records'
export {
  fetchKeeperTurnRecords,
  fetchKeeperTurnTranscript,
} from './dashboard-turn-records'

export type {
  TelemetrySource,
  TelemetryEntry,
  TelemetryResponse,
  DashboardCacheEntryDetail,
  DashboardCacheStatsResponse,
  TelemetrySourceSummary,
  TelemetrySummaryResponse,
} from './dashboard-telemetry'
export {
  fetchTelemetry,
  fetchTelemetrySummary,
  fetchDashboardCacheStats,
} from './dashboard-telemetry'

// --- Excuse Patterns ---

export type ExcusePattern = [string, string]

export function fetchExcusePatterns(): Promise<ExcusePattern[]> {
  return get<ExcusePattern[]>('/api/v1/dashboard/config/excuse-patterns')
}

export function updateExcusePatterns(patterns: ExcusePattern[]): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/dashboard/config/excuse-patterns', patterns)
}

// --- Memory Subsystems ---

export interface MemorySubsystemsSynapse {
  from_agent: string
  to_agent: string
  weight: number
  success_count: number
  failure_count: number
  last_updated: number
  created_at: number
  /** Newest-first list of (unix ts seconds, weight) points, capped at 30.
      Missing for graphs produced by pre-sparkline backends. */
  weight_history?: Array<[number, number]>
}

export interface MemorySubsystemsEpisode {
  id: string
  timestamp: number
  participants: string[]
  event_type: string
  summary: string
  outcome: string
  learnings: string[]
  context: Record<string, string>
}

export interface MemorySubsystemsMemoryEntry {
  keeper: string
  kind: string
  text: string
  priority: number
  ts_unix: number
}

/** RFC-0149 §3.1 — per-keeper memory bank read failure, surfaced as
 *  a typed sibling field next to the entry rows.  `error_class` is one
 *  of the closed 4-value `Keeper_memory_recall_exn_class.t` labels
 *  (`yojson_parse_error | io_error | type_error | other`). */
export interface MemorySubsystemsMemoryEntryError {
  keeper: string
  error_class: string
}

export interface MemorySubsystemsUserModelItem {
  keeper: string
  kind: 'preference' | 'constraint' | string
  claim: string
  source_ref: string
  source_trace_id: string
  source_turn: number
  first_seen: number
  last_verified_at: number | null
  observed_by: string[]
}

export interface MemorySubsystemsUserModelError {
  keeper: string
  error: string
}

export interface MemorySubsystemsUserModelPrompt {
  enabled: boolean
  block_id: string
  injection: string
  runtime_hook: string
  producer?: string
}

export interface MemorySubsystemsDraftSkillCandidate {
  id: string
  agent_name: string
  source_kind: string
  source_ref: string
  promotion_state: string
  dir: string
  json_path: string
  toml_path: string
  skill_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsDelegationRequest {
  id: string
  requester: string
  topic: string
  goal: string | null
  promotion_state: string
  dir: string
  json_path: string
  task_seed_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsResponse {
  generated_at: string
  hebbian: {
    synapses: MemorySubsystemsSynapse[]
    last_consolidation: number
  }
  episodes: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsEpisode[]
  }
  memory_entries?: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsMemoryEntry[]
    /** RFC-0149 §3.1 — per-keeper memory bank read failures.  Each
     *  entry means that keeper's `memory.jsonl` could not be read and
     *  the corresponding rows are absent from `items`; the rest of
     *  `items` is still trustworthy. */
    errors?: MemorySubsystemsMemoryEntryError[]
  }
  user_model?: {
    schema: string
    source: string
    prompt?: MemorySubsystemsUserModelPrompt
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsUserModelItem[]
    errors?: MemorySubsystemsUserModelError[]
  }
  draft_skill_candidates?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDraftSkillCandidate[]
    error?: string | null
  }
  delegation_requests?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDelegationRequest[]
    error?: string | null
  }
  filters: {
    keepers: string[]
    outcomes: string[]
    memory_kinds?: string[]
  }
}

interface MemorySubsystemsQuery {
  limit?: number
  keeper?: string
  outcome?: string
  q?: string
  includeMemoryEntries?: boolean
  signal?: AbortSignal
}

export function fetchMemorySubsystems(
  opts?: MemorySubsystemsQuery,
): Promise<MemorySubsystemsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit != null) params.set('limit', String(opts.limit))
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.outcome) params.set('outcome', opts.outcome)
  if (opts?.q) params.set('q', opts.q)
  if (opts?.includeMemoryEntries) params.set('include_memory_entries', 'true')
  const qs = params.toString()
  return get<MemorySubsystemsResponse>(
    `/api/v1/dashboard/memory-subsystems${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

// --- Keeper Memory Health ---

export interface KeeperMemoryHealthKeeperEntry {
  keeper_id: string
  facts: number
  facts_bytes: number
  events: number
  events_bytes: number
  events_to_facts_ratio: number
  ttl_expired_on_disk: number
  near_duplicate: number
  external_ref: number
}

export interface KeeperMemoryHealthResponse {
  generated_at: number
  cadence_counter_entries: number
  keepers: KeeperMemoryHealthKeeperEntry[]
  totals: {
    facts: number
    facts_bytes: number
    events_bytes: number
    ttl_expired_on_disk: number
    near_duplicate: number
  }
}

export function fetchKeeperMemoryHealth(): Promise<KeeperMemoryHealthResponse> {
  return get<KeeperMemoryHealthResponse>('/api/v1/dashboard/keeper-memory-health')
}

// --- Verification requests (Mission detail table) ---
// Backend: lib/dashboard/dashboard_verification.ml
// Route:   GET /api/v1/verification/requests?task_id=&limit=
// Shape is stable; status values match the Verification state machine's
// user-visible mapping (pending → approved | rejected, plus a reserved
// timed_out slot for the deadline watcher).

export type VerificationRequestStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'timed_out'

export type VerificationRequestVerdict = 'pass' | 'fail' | 'partial' | null

export interface VerificationRequest {
  request_id: string
  task_id: string
  task_title: string
  request_kind: 'normal' | 'conflict_triage'
  request_summary: string
  next_action: string | null
  keeper: string | null
  status: VerificationRequestStatus
  created_at: string
  submitted_by: string
  approved_by: string | null
  completion_contract: string[]
  required_evidence: string[]
  verdict: VerificationRequestVerdict
  verdict_reason: string
}

export interface VerificationRequestsResponse {
  updated_at: string
  total: number
  requests: VerificationRequest[]
}

interface FetchVerificationRequestsOptions {
  taskId?: string
  limit?: number
  signal?: AbortSignal
}

export function fetchVerificationRequests(
  opts?: FetchVerificationRequestsOptions,
): Promise<VerificationRequestsResponse> {
  const params = new URLSearchParams()
  if (opts?.taskId && opts.taskId.trim() !== '') {
    params.set('task_id', opts.taskId.trim())
  }
  if (opts?.limit != null) {
    params.set('limit', String(opts.limit))
  }
  const qs = params.toString()
  const path = qs.length > 0
    ? `/api/v1/verification/requests?${qs}`
    : '/api/v1/verification/requests'
  return get<VerificationRequestsResponse>(path, { signal: opts?.signal })
}

interface ResolveVerificationRequestOptions {
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  reason?: string
}

interface ResolveVerificationResponse {
  ok: boolean
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  verifier: string
}

export function resolveVerificationRequest(
  opts: ResolveVerificationRequestOptions,
): Promise<ResolveVerificationResponse> {
  return post<ResolveVerificationResponse>('/api/v1/verification/resolve', {
    task_id: opts.task_id,
    verification_id: opts.verification_id,
    decision: opts.decision,
    reason: opts.reason ?? '',
  })
}

export type TlaSpecCategory = 'boundary' | 'bug-models' | 'other'

export interface TlaSpecEntry {
  name: string
  path: string
  category: TlaSpecCategory
  has_clean_cfg: boolean
  has_buggy_cfg: boolean
  mtime_iso: string
}

export interface TlaSpecsResponse {
  updated_at: string
  specs_dir: string | null
  count: number
  entries: TlaSpecEntry[]
}

export function fetchTlaSpecs(
  opts?: AbortableRequestOptions,
): Promise<TlaSpecsResponse> {
  return get<TlaSpecsResponse>('/api/v1/verification/specs', {
    signal: opts?.signal,
  })
}

export type TlcResultStatus =
  | 'passed'
  | 'violated'
  | 'running'
  | 'queued'
  | 'error'
  | 'not_run'

export interface TlcResultEntry {
  spec_name: string
  cfg_name: string
  category: TlaSpecCategory
  status: TlcResultStatus
  states_explored: number | null
  distinct_states: number | null
  diameter: number | null
  last_run_at: string | null
  violation: string | null
  log_path: string | null
}

export interface TlcResultsResponse {
  updated_at: string
  results_dir: string | null
  count: number
  entries: TlcResultEntry[]
}

export function fetchTlcResults(
  opts?: AbortableRequestOptions,
): Promise<TlcResultsResponse> {
  return get<TlcResultsResponse>('/api/v1/verification/tlc-results', {
    signal: opts?.signal,
  })
}

export interface AuditEntry {
  id: string
  ts: string
  actor: string
  kind: string
  target?: string
  summary: string
  severity: string
  payload?: unknown
}

export interface AuditLedgerResponse {
  entries: AuditEntry[]
  count: number
}

export interface AuditLedgerParams {
  limit?: number
  actor?: string
  kind?: string
  severity?: string
  since?: number
  until?: number
}

export function fetchAuditLedger(
  params: AuditLedgerParams = {},
  opts?: { signal?: AbortSignal },
): Promise<AuditLedgerResponse> {
  const { limit = 100, actor, kind, severity, since, until } = params
  const qs = new URLSearchParams()
  qs.set('limit', String(limit))
  if (actor) qs.set('actor', actor)
  if (kind) qs.set('kind', kind)
  if (severity) qs.set('severity', severity)
  if (since != null) qs.set('since', String(since))
  if (until != null) qs.set('until', String(until))
  return get<AuditLedgerResponse>(`/api/v1/audit?${qs.toString()}`, {
    signal: opts?.signal,
  })
}

