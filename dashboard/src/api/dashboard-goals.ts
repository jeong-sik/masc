// MASC Dashboard — Goals projections (goal tree + detail + verification).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asBoolean, asInt, asNullableString, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { normalizeKeeperTrustTerminalReason } from '../keeper-store-normalize'
import { get } from './core'
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
  const status = asString(raw.status)
  if (!id || !title || !status) return null
  return {
    id,
    title,
    status,
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
      next_actions: [],
      activity_observation: 'goal_metadata',
      stagnation_status: 'recent',
    }
  }
  const state = asString(raw.state, phase)
  return {
    state,
    source: asString(raw.source, 'goal.phase'),
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
      metric_evaluation: fallback.metric != null ? 'unevaluated' : 'absent',
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
  const metric = asNullableString(raw.metric) ?? fallback.metric
  return {
    state: asString(raw.state, 'unmeasured'),
    basis: asString(raw.basis, 'unmeasured'),
    metric,
    // Fall back to deriving from metric presence when the server field is
    // absent (old payloads), matching the server's own rule.
    metric_evaluation: asString(raw.metric_evaluation, metric != null ? 'unevaluated' : 'absent'),
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
    metric_evaluation: asString(raw.metric_evaluation, 'absent'),
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
  const status = asString(raw.status)
  if (!id || !title || !status) return null
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
    status,
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
