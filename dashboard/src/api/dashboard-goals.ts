import { decodeGoalProof } from './goal-proof'
// MASC Dashboard — Goals projections (goal tree + detail).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asBoolean, asInt, asNullableString, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { normalizeKeeperTrustTerminalReason } from '../keeper-store-normalize'
import { get } from './core'
import { decodeKeeperApprovalQueueState } from './dashboard-gate'
import { goalStoreUnavailableSummary } from '../lib/goal-store-unavailable-labels'
import {
  GOAL_STORE_MIRROR_STATUSES,
  GOAL_STORE_RESET_STEPS,
  GOAL_STORE_UNAVAILABLE_REASONS,
} from '../types/goal-store-unavailable'
import type {
  GoalSourceUnavailable,
  GoalStoreMirror,
  GoalStoreUnavailable,
  DashboardGoalsTreeResponse,
  DashboardGoalDetailResponse,
  GoalDetailKeeper,
  GoalKeeperTrustApprovalState,
  GoalKeeperTrustExecutionSummary,
  GoalKeeperTrustLatestEvent,
  GoalKeeperTrustSummary,
  GoalDetailTimelineEvent,
  GoalTaskSummary,
  GoalTreeNode,
  GoalTreeSummary,
  GoalTreeTask,
  KeeperApprovalQueueState,
} from '../types'

// ── Goal source unavailable envelopes (RFC-0444 §2.3 row 4) ─────────────────

/** The envelope named a Goal source failure but its members do not parse. */
export class GoalStoreEnvelopeError extends Error {
  constructor(detail: string) {
    super(`invalid goal_store_unavailable envelope: ${detail}`)
    this.name = 'GoalStoreEnvelopeError'
  }
}

/** A fetch answered with a parsed Goal source failure instead of a snapshot. */
export class GoalSourceUnavailableError extends Error {
  readonly unavailable: GoalSourceUnavailable

  constructor(unavailable: GoalSourceUnavailable) {
    super(goalSourceUnavailableMessage(unavailable))
    this.name = 'GoalSourceUnavailableError'
    this.unavailable = unavailable
  }
}

function goalSourceUnavailableMessage(unavailable: GoalSourceUnavailable): string {
  switch (unavailable.kind) {
    case 'unavailable':
      return goalStoreUnavailableSummary(unavailable)
    case 'links_unavailable':
      return unavailable.detail
    default: {
      const unhandled: never = unavailable
      return unhandled
    }
  }
}

function wireToken<T extends string>(tokens: readonly T[], value: unknown): T | null {
  return typeof value === 'string' && (tokens as readonly string[]).includes(value)
    ? (value as T)
    : null
}

const GOAL_STORE_ENVELOPE_KEY_COUNT = 7
const GOAL_STORE_MIRROR_KEY_COUNT = 2

function decodeGoalStoreMirror(raw: unknown): GoalStoreMirror {
  if (!isRecord(raw) || Object.keys(raw).length !== GOAL_STORE_MIRROR_KEY_COUNT) {
    throw new GoalStoreEnvelopeError('mirror is not a {status, goal_count} object')
  }
  const status = wireToken(GOAL_STORE_MIRROR_STATUSES, raw.status)
  if (status === null) throw new GoalStoreEnvelopeError(`unknown mirror status ${JSON.stringify(raw.status)}`)
  switch (status) {
    case 'mirror_decodes': {
      const goalCount = raw.goal_count
      if (typeof goalCount !== 'number' || !Number.isSafeInteger(goalCount) || goalCount < 0) {
        throw new GoalStoreEnvelopeError('mirror_decodes carries no goal_count')
      }
      return { status, goalCount }
    }
    case 'mirror_absent':
    case 'mirror_unreadable':
    case 'mirror_rejected':
      if (raw.goal_count !== null) throw new GoalStoreEnvelopeError(`${status} carries a goal_count`)
      return { status, goalCount: null }
    default: {
      const unhandled: never = status
      return unhandled
    }
  }
}

function decodeGoalStoreUnavailable(raw: Record<string, unknown>): GoalStoreUnavailable {
  if (Object.keys(raw).length !== GOAL_STORE_ENVELOPE_KEY_COUNT) {
    throw new GoalStoreEnvelopeError(`expected ${GOAL_STORE_ENVELOPE_KEY_COUNT} members, got ${Object.keys(raw).length}`)
  }
  const reason = wireToken(GOAL_STORE_UNAVAILABLE_REASONS, raw.reason)
  if (reason === null) throw new GoalStoreEnvelopeError(`unknown reason ${JSON.stringify(raw.reason)}`)
  const resetStep = wireToken(GOAL_STORE_RESET_STEPS, raw.reset_step)
  if (resetStep === null) throw new GoalStoreEnvelopeError(`unknown reset_step ${JSON.stringify(raw.reset_step)}`)
  if (typeof raw.file !== 'string' || raw.file.length === 0) throw new GoalStoreEnvelopeError('file is not a path')
  let field: string | null
  switch (reason) {
    case 'schema_rejected':
      if (typeof raw.field !== 'string' || raw.field.length === 0) {
        throw new GoalStoreEnvelopeError('schema_rejected names no field')
      }
      field = raw.field
      break
    case 'missing_after_init':
    case 'unreadable':
    case 'not_json':
      if (raw.field !== null) throw new GoalStoreEnvelopeError(`${reason} carries a field`)
      field = null
      break
    default: {
      const unhandled: never = reason
      return unhandled
    }
  }
  return {
    kind: 'unavailable',
    reason,
    field,
    file: raw.file,
    mirror: decodeGoalStoreMirror(raw.mirror),
    resetStep,
  }
}

/**
 * Parses a projection body into the closed Goal source failure union.
 * Returns null when the body is not a failure envelope at all; throws
 * {@link GoalStoreEnvelopeError} when it names one but a member does not
 * parse — an unknown token is refused, never mapped to a default.
 */
export function goalSourceUnavailable(raw: unknown): GoalSourceUnavailable | null {
  if (!isRecord(raw) || raw.ok !== false) return null
  if (raw.error_code === 'goal_task_links_unavailable') {
    if (typeof raw.error !== 'string' || raw.error.length === 0) {
      throw new GoalStoreEnvelopeError('goal_task_links_unavailable carries no error line')
    }
    return { kind: 'links_unavailable', detail: raw.error }
  }
  if (raw.error_code !== 'goal_store_unavailable') return null
  return decodeGoalStoreUnavailable(raw)
}

export class DashboardGoalsApprovalQueueUnavailableError extends Error {
  readonly approval_queue_state: Extract<KeeperApprovalQueueState, { state: 'unavailable' }>

  constructor(state: Extract<KeeperApprovalQueueState, { state: 'unavailable' }>) {
    super(`${state.icon} ${state.title}: ${state.operator_detail}`)
    this.name = 'DashboardGoalsApprovalQueueUnavailableError'
    this.approval_queue_state = state
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
    is_terminal: asBoolean(raw.is_terminal, false),
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
    // Aged-out cancellations reach Work only through this tree, and only
    // through this decoder. Dropping them here left the card as a bare
    // cancelled in production while tests that assign goalTreeData directly
    // still passed.
    cancelled_by: asNullableString(raw.cancelled_by),
    reason: asNullableString(raw.reason),
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
  }
}

function decodeGoalTreeNode(raw: unknown): GoalTreeNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const phase = asString(raw.phase)
  if (!id || !title || !phase) return null
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
  return {
    id,
    title,
    phase,
    phase_color: asString(raw.phase_color, ''),
    goal_fsm: decodeGoalFsmProjection(raw.goal_fsm, phase),
    verification: decodeGoalProof(raw.verification),
    priority: asInt(raw.priority) ?? 0,
    metric,
    target_value: targetValue,
    due_date: asNullableString(raw.due_date),
    tasks,
    task_count: taskCount,
    task_done_count: taskDoneCount,
    task_summary: decodeGoalTaskSummary(raw.task_summary, {
      taskCount,
      taskDoneCount,
      tasks,
    }),
    timeline_events: asRecordArray(raw.timeline_events)
      .map(decodeGoalDetailTimelineEvent)
      .filter((event): event is GoalDetailTimelineEvent => event !== null),
    children,
    child_count: asInt(raw.child_count) ?? children.length,
    last_activity_at: asString(raw.last_activity_at, ''),
    stagnation_seconds: asInt(raw.stagnation_seconds) ?? null,
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    linked_keeper_names: asStringArray(raw.linked_keeper_names),
    pending_approval_count: asInt(raw.pending_approval_count) ?? 0,
    latest_keeper_ref: asNullableString(raw.latest_keeper_ref),
    latest_turn_ref: asInt(raw.latest_turn_ref) ?? null,
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalTreeSummary(raw: unknown): GoalTreeSummary | null {
  if (!isRecord(raw)) return null
  return {
    total_goals: asInt(raw.total_goals) ?? 0,
    active_goals: asInt(raw.active_goals) ?? 0,
    phase_counts: decodeNumberRecord(raw.phase_counts),
    total_tasks: asInt(raw.total_tasks) ?? 0,
    done_tasks: asInt(raw.done_tasks) ?? 0,
    pending_approvals: asInt(raw.pending_approvals) ?? 0,
  }
}

function requireReadyApprovalQueue(raw: Record<string, unknown>) {
  const state = decodeKeeperApprovalQueueState(raw.approval_queue_state)
  if (!state) {
    throw new Error('유효하지 않은 dashboard goals approval_queue_state payload')
  }
  if (state.state === 'unavailable') {
    throw new DashboardGoalsApprovalQueueUnavailableError(state)
  }
  return state
}

function decodeGoalDetailKeeper(raw: unknown): GoalDetailKeeper | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const sandboxProfile = asString(raw.sandbox_profile)
  const networkMode = asString(raw.network_mode)
  const runtimeName = asString(raw.runtime_id)
  if (!name || !sandboxProfile || !networkMode || !runtimeName) return null
  return {
    name,
    current_task_id: asNullableString(raw.current_task_id),
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
  const approvalQueueState = requireReadyApprovalQueue(raw)
  if (!Array.isArray(raw.tree)) return null
  const tree = asRecordArray(raw.tree)
    .map(decodeGoalTreeNode)
    .filter((node): node is GoalTreeNode => node !== null)
  const summary = decodeGoalTreeSummary(raw.summary)
  if (!summary) return null
  const generatedAt = asString(raw.generated_at)
  return generatedAt
    ? { generated_at: generatedAt, approval_queue_state: approvalQueueState, tree, summary }
    : { approval_queue_state: approvalQueueState, tree, summary }
}

function decodeDashboardGoalDetailResponse(raw: unknown): DashboardGoalDetailResponse | null {
  if (!isRecord(raw)) return null
  requireReadyApprovalQueue(raw)
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
  const unavailable = goalSourceUnavailable(raw)
  if (unavailable !== null) throw new GoalSourceUnavailableError(unavailable)
  const decoded = decodeDashboardGoalsTreeResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goals payload')
  return decoded
}

export async function fetchDashboardGoalDetail(goalId: string): Promise<DashboardGoalDetailResponse> {
  const raw = await get<unknown>(`/api/v1/dashboard/goals/detail?goal_id=${encodeURIComponent(goalId)}`)
  const unavailable = goalSourceUnavailable(raw)
  if (unavailable !== null) throw new GoalSourceUnavailableError(unavailable)
  const decoded = decodeDashboardGoalDetailResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goal detail payload')
  return decoded
}
