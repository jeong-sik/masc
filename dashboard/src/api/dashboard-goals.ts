// MASC Dashboard — Goals projections (goal tree + detail).
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
} from '../types'

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
    }
  }
  const state = asString(raw.state, phase)
  return {
    state,
    source: asString(raw.source, 'goal.phase'),
    next_actions: asStringArray(raw.next_actions),
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
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
    completion_observation_summary: asNullableString(raw.completion_observation_summary),
    latest_receipt_at: asNullableString(raw.latest_receipt_at),
  }
}

function decodeGoalKeeperTrustSummary(raw: unknown): GoalKeeperTrustSummary | null {
  if (!isRecord(raw)) return null
  return {
    snapshot_status: asNullableString(raw.snapshot_status),
    snapshot_error: asNullableString(raw.snapshot_error),
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

function decodeMetricEvaluation(raw: unknown): 'unevaluated' | 'absent' | undefined {
  const s = asString(raw)
  if (s === 'unevaluated') return 'unevaluated'
  if (s === 'absent') return 'absent'
  return undefined
}

function metricEvaluationForMetric(metric: string | null): 'unevaluated' | 'absent' {
  return metric != null ? 'unevaluated' : 'absent'
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
      metric_evaluation: metricEvaluationForMetric(fallback.metric),
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
    metric_evaluation:
      decodeMetricEvaluation(raw.metric_evaluation) ?? metricEvaluationForMetric(metric),
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
    metric_evaluation: decodeMetricEvaluation(raw.metric_evaluation) ?? 'absent',
    task_total: asInt(raw.task_total) ?? 0,
    task_done: asInt(raw.task_done) ?? 0,
    task_open: asInt(raw.task_open) ?? 0,
    is_complete: asBoolean(raw.is_complete) ?? false,
    is_terminal: asBoolean(raw.is_terminal) ?? false,
    ready_to_request_completion: asBoolean(raw.ready_to_request_completion) ?? false,
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
  return {
    id,
    title,
    status,
    status_color: asString(raw.status_color, ''),
    phase: asString(raw.phase, 'unknown'),
    phase_color: asString(raw.phase_color, ''),
    goal_fsm: decodeGoalFsmProjection(raw.goal_fsm, asString(raw.phase, 'unknown')),
    priority: asInt(raw.priority) ?? 0,
    metric,
    target_value: targetValue,
    due_date: asNullableString(raw.due_date),
    parent_goal_id: asNullableString(raw.parent_goal_id),
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
    timeline_events: Array.isArray(raw.timeline_events) ? raw.timeline_events : [],
    children,
    child_count: asInt(raw.child_count) ?? children.length,
    last_activity_at: asString(raw.last_activity_at, ''),
    stagnation_seconds: asInt(raw.stagnation_seconds) ?? null,
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    linked_keeper_names: asStringArray(raw.linked_keeper_names),
    pending_approval_count: asInt(raw.pending_approval_count) ?? 0,
    linkage_source: asString(raw.linkage_source, 'none'),
    latest_keeper_ref: asNullableString(raw.latest_keeper_ref),
    latest_turn_ref: asInt(raw.latest_turn_ref) ?? null,
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalTreeSummary(raw: unknown): GoalTreeSummary {
  if (!isRecord(raw)) {
    return {
      total_goals: 0,
      active_goals: 0,
      phase_counts: {},
      total_tasks: 0,
      done_tasks: 0,
      pending_approvals: 0,
    }
  }
  return {
    total_goals: asInt(raw.total_goals) ?? 0,
    active_goals: asInt(raw.active_goals) ?? 0,
    phase_counts: decodeNumberRecord(raw.phase_counts),
    total_tasks: asInt(raw.total_tasks) ?? 0,
    done_tasks: asInt(raw.done_tasks) ?? 0,
    pending_approvals: asInt(raw.pending_approvals) ?? 0,
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
