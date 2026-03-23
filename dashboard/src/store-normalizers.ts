import { isRecord, asString, asNumber, asBoolean, asStringArray, toIsoTimestamp } from './components/common/normalize'
import type {
  Agent, Task, Message, ServerStatus,
  DashboardExecutionSummary, DashboardExecutionHandoff,
  DashboardExecutionQueueItem, DashboardExecutionSessionBrief,
  DashboardExecutionOperationBrief, DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief, MdalLoop, MdalIterationRecord,
  OperatorAttentionItem, OperatorRecommendedAction,
} from './types'

// --- Data fetchers ---

export function normalizeAgentStatus(value: unknown): Agent['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (
    raw === 'active'
    || raw === 'busy'
    || raw === 'listening'
    || raw === 'idle'
    || raw === 'inactive'
    || raw === 'offline'
  ) {
    return raw
  }
  if (raw === 'in_progress' || raw === 'claimed') return 'busy'
  if (raw === 'dead' || raw === 'left') return 'offline'
  return undefined
}

export function normalizeTaskStatus(value: unknown): Task['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'todo' || raw === 'in_progress' || raw === 'claimed' || raw === 'done' || raw === 'cancelled') {
    return raw
  }
  if (raw === 'inprogress') return 'in_progress'
  return undefined
}

export function normalizeAgent(raw: unknown): Agent | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    agent_type: asString(raw.agent_type),
    status: normalizeAgentStatus(raw.status),
    current_task: asString(raw.current_task) ?? null,
    joined_at: asString(raw.joined_at),
    last_seen: asString(raw.last_seen),
    capabilities: asStringArray(raw.capabilities),
    emoji: asString(raw.emoji),
    koreanName: asString(raw.koreanName) ?? asString(raw.korean_name),
    model: asString(raw.model),
    traits: asStringArray(raw.traits),
    interests: asStringArray(raw.interests),
    activityLevel: asNumber(raw.activityLevel) ?? asNumber(raw.activity_level),
    primaryValue: asString(raw.primaryValue) ?? asString(raw.primary_value),
  }
}

export function normalizeTask(raw: unknown): Task | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  if (!id || !title) return null
  return {
    id,
    title,
    status: normalizeTaskStatus(raw.status),
    priority: asNumber(raw.priority),
    assignee: asString(raw.assignee),
    description: asString(raw.description),
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
  }
}

export function normalizeMessage(raw: unknown): Message | null {
  if (!isRecord(raw)) return null
  const from = asString(raw.from) ?? asString(raw.from_agent)
  const content = asString(raw.content) ?? ''
  const timestamp = asString(raw.timestamp)
  return {
    id: asString(raw.id),
    seq: asNumber(raw.seq),
    from,
    content,
    timestamp,
    type: asString(raw.type),
  }
}

export function normalizeExecutionTone(value: unknown): DashboardExecutionQueueItem['severity'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'ok' || raw === 'warn' || raw === 'bad') return raw
  return undefined
}

export function normalizeExecutionSummary(raw: unknown): DashboardExecutionSummary | null {
  if (!isRecord(raw)) return null
  return {
    active_sessions: asNumber(raw.active_sessions),
    blocked_sessions: asNumber(raw.blocked_sessions),
    active_operations: asNumber(raw.active_operations),
    blocked_operations: asNumber(raw.blocked_operations),
    runtime_pressure: asNumber(raw.runtime_pressure),
    worker_alerts: asNumber(raw.worker_alerts),
    continuity_alerts: asNumber(raw.continuity_alerts),
    priority_items: asNumber(raw.priority_items),
    todo_tasks: asNumber(raw.todo_tasks),
    claimed_tasks: asNumber(raw.claimed_tasks),
    running_tasks: asNumber(raw.running_tasks),
    done_tasks: asNumber(raw.done_tasks),
    cancelled_tasks: asNumber(raw.cancelled_tasks),
    keepers: asNumber(raw.keepers),
  }
}

export function normalizeExecutionHandoff(raw: unknown): DashboardExecutionHandoff | null {
  if (!isRecord(raw)) return null
  const surface = asString(raw.surface)
  const label = asString(raw.label)
  const targetType = asString(raw.target_type)
  const targetId = asString(raw.target_id)
  const focusKind = asString(raw.focus_kind)
  if (!surface || !label || !targetType || !targetId || !focusKind) return null
  return {
    surface: surface === 'command' ? 'command' : 'intervene',
    label,
    target_type: targetType,
    target_id: targetId,
    focus_kind: focusKind,
    operation_id: asString(raw.operation_id) ?? null,
    command_surface: asString(raw.command_surface) ?? null,
  }
}

export function normalizeExecutionQueueItem(raw: unknown): DashboardExecutionQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  const targetId = asString(raw.target_id)
  if (!id || !summary || !targetType || !targetId || (kind !== 'session' && kind !== 'operation')) {
    return null
  }
  return {
    id,
    kind,
    severity: normalizeExecutionTone(raw.severity),
    status: asString(raw.status),
    summary,
    target_type: targetType,
    target_id: targetId,
    linked_session_id: asString(raw.linked_session_id) ?? null,
    linked_operation_id: asString(raw.linked_operation_id) ?? null,
    last_seen_at: asString(raw.last_seen_at) ?? null,
    top_handoff: normalizeExecutionHandoff(raw.top_handoff),
    intervene_handoff: normalizeExecutionHandoff(raw.intervene_handoff),
    command_handoff: normalizeExecutionHandoff(raw.command_handoff),
  }
}

export function normalizeExecutionSessionBrief(raw: unknown): DashboardExecutionSessionBrief | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  const goal = asString(raw.goal)
  if (!sessionId || !goal) return null
  return {
    session_id: sessionId,
    goal,
    room: asString(raw.room) ?? null,
    status: asString(raw.status),
    health: asString(raw.health),
    member_names: asStringArray(raw.member_names),
    linked_operation_id: asString(raw.linked_operation_id) ?? null,
    linked_detachment_id: asString(raw.linked_detachment_id) ?? null,
    runtime_blocker: asString(raw.runtime_blocker) ?? null,
    worker_gap_summary: asString(raw.worker_gap_summary) ?? null,
    last_activity_at: asString(raw.last_activity_at) ?? null,
    last_activity_summary: asString(raw.last_activity_summary) ?? null,
    communication_summary: asString(raw.communication_summary) ?? null,
    active_count: asNumber(raw.active_count),
    seen_count: asNumber(raw.seen_count),
    planned_count: asNumber(raw.planned_count),
    required_count: asNumber(raw.required_count),
    counts_basis: asString(raw.counts_basis) ?? null,
    top_handoff: normalizeExecutionHandoff(raw.top_handoff),
    intervene_handoff: normalizeExecutionHandoff(raw.intervene_handoff),
    command_handoff: normalizeExecutionHandoff(raw.command_handoff),
  }
}

export function normalizeExecutionOperationBrief(raw: unknown): DashboardExecutionOperationBrief | null {
  if (!isRecord(raw)) return null
  const operationId = asString(raw.operation_id)
  const objective = asString(raw.objective)
  if (!operationId || !objective) return null
  return {
    operation_id: operationId,
    objective,
    status: asString(raw.status),
    stage: asString(raw.stage) ?? null,
    assigned_unit_id: asString(raw.assigned_unit_id) ?? null,
    assigned_unit_label: asString(raw.assigned_unit_label) ?? null,
    linked_session_id: asString(raw.linked_session_id) ?? null,
    linked_detachment_id: asString(raw.linked_detachment_id) ?? null,
    blocker_summary: asString(raw.blocker_summary) ?? null,
    search_status: asString(raw.search_status) ?? null,
    next_tool: asString(raw.next_tool) ?? null,
    updated_at: asString(raw.updated_at) ?? null,
    top_handoff: normalizeExecutionHandoff(raw.top_handoff),
    command_handoff: normalizeExecutionHandoff(raw.command_handoff),
  }
}

export function normalizeExecutionWorkerSupportBrief(raw: unknown): DashboardExecutionWorkerSupportBrief | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name) ?? asString(raw.agent_name)
  const note = asString(raw.note)
  const focus = asString(raw.focus)
  const state = asString(raw.state)
  if (!name || !note || !focus || (state !== 'working' && state !== 'watching' && state !== 'quiet' && state !== 'offline')) {
    return null
  }
  const signalTruthRaw = asString(raw.signal_truth)
  const signalTruth =
    signalTruthRaw === 'live' || signalTruthRaw === 'stale' || signalTruthRaw === 'absent'
      ? signalTruthRaw
      : undefined
  const evidenceSourceRaw = asString(raw.evidence_source)
  const evidenceSource =
    evidenceSourceRaw === 'message' || evidenceSourceRaw === 'presence' || evidenceSourceRaw === 'none'
      ? evidenceSourceRaw
      : undefined
  return {
    name,
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    tone: normalizeExecutionTone(raw.tone),
    state,
    note,
    focus,
    last_signal_at: asString(raw.last_signal_at) ?? null,
    last_signal_age_sec: asNumber(raw.last_signal_age_sec) ?? null,
    signal_truth: signalTruth,
    evidence_source: evidenceSource,
    active_task_count: asNumber(raw.active_task_count),
    related_session_id: asString(raw.related_session_id) ?? null,
    related_operation_id: asString(raw.related_operation_id) ?? null,
    emoji: asString(raw.emoji),
    korean_name: asString(raw.korean_name),
    model: asString(raw.model) ?? null,
    recent_output_preview: asString(raw.recent_output_preview) ?? null,
    recent_event: asString(raw.recent_event) ?? null,
  }
}

export function normalizeExecutionContinuityBrief(raw: unknown): DashboardExecutionContinuityBrief | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const note = asString(raw.note)
  const focus = asString(raw.focus)
  const state = asString(raw.state)
  if (!name || !note || !focus || (state !== 'healthy' && state !== 'warning' && state !== 'critical')) {
    return null
  }
  return {
    name,
    agent_name: asString(raw.agent_name) ?? null,
    status: asString(raw.status),
    tone: normalizeExecutionTone(raw.tone),
    state,
    note,
    focus,
    last_signal_at: asString(raw.last_signal_at) ?? null,
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    generation: asNumber(raw.generation),
    turn_count: asNumber(raw.turn_count),
    context_ratio: asNumber(raw.context_ratio) ?? null,
    continuity: asString(raw.continuity) ?? null,
    lifecycle: asString(raw.lifecycle) ?? null,
    related_session_id: asString(raw.related_session_id) ?? null,
    model: asString(raw.model) ?? null,
    emoji: asString(raw.emoji),
    korean_name: asString(raw.korean_name),
    skill_reason: asString(raw.skill_reason) ?? null,
    recent_input_preview: asString(raw.recent_input_preview) ?? null,
    recent_output_preview: asString(raw.recent_output_preview) ?? null,
    recent_tool_names: asStringArray(raw.recent_tool_names) ?? [],
    allowed_tool_names: asStringArray(raw.allowed_tool_names) ?? [],
    latest_tool_names: asStringArray(raw.latest_tool_names) ?? [],
    latest_tool_call_count: asNumber(raw.latest_tool_call_count) ?? null,
    tool_audit_source: asString(raw.tool_audit_source) ?? null,
    tool_audit_at: asString(raw.tool_audit_at) ?? null,
    last_proactive_preview: asString(raw.last_proactive_preview) ?? null,
    continuity_summary: asString(raw.continuity_summary) ?? null,
    skill_route_summary: asString(raw.skill_route_summary) ?? null,
  }
}

export function normalizeAttentionItem(raw: unknown): OperatorAttentionItem | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!kind || !summary || !targetType) return null
  return {
    kind,
    severity: asString(raw.severity) ?? 'unknown',
    summary,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    actor: asString(raw.actor) ?? null,
    evidence: raw.evidence,
  }
}

export function normalizeRecommendedAction(raw: unknown): OperatorRecommendedAction | null {
  if (!isRecord(raw)) return null
  const actionType = asString(raw.action_type)
  const targetType = asString(raw.target_type)
  const reason = asString(raw.reason)
  if (!actionType || !targetType || !reason) return null
  return {
    action_type: actionType,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    severity: asString(raw.severity) ?? 'unknown',
    reason,
    confirm_required: asBoolean(raw.confirm_required),
    suggested_payload: isRecord(raw.suggested_payload) ? raw.suggested_payload : undefined,
    preview: raw.preview,
  }
}

export function messageSortKey(message: Message): number {
  if (typeof message.seq === 'number' && Number.isFinite(message.seq)) return message.seq
  const parsed = Date.parse(message.timestamp ?? '')
  return Number.isNaN(parsed) ? 0 : parsed
}

export function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  if (incoming.length === 0) return current
  const byKey = new Map<string, Message>()
  for (const message of current) {
    const key = typeof message.seq === 'number'
      ? `seq:${message.seq}`
      : `ts:${message.timestamp ?? ''}|from:${message.from ?? ''}|content:${message.content}`
    byKey.set(key, message)
  }
  for (const message of incoming) {
    const key = typeof message.seq === 'number'
      ? `seq:${message.seq}`
      : `ts:${message.timestamp ?? ''}|from:${message.from ?? ''}|content:${message.content}`
    byKey.set(key, message)
  }
  return [...byKey.values()]
    .sort((a, b) => messageSortKey(a) - messageSortKey(b))
    .slice(-500)
}

export function normalizeBuildIdentity(raw: unknown): ServerStatus['build'] | undefined {
  if (!isRecord(raw)) return undefined
  const releaseVersion = asString(raw.release_version)
  const startedAt = toIsoTimestamp(raw.started_at)
  const uptimeSeconds = asNumber(raw.uptime_seconds)
  if (!releaseVersion || !startedAt || uptimeSeconds == null) return undefined
  return {
    release_version: releaseVersion,
    commit: asString(raw.commit) ?? null,
    started_at: startedAt,
    uptime_seconds: uptimeSeconds,
  }
}

export function normalizeServerStatus(raw: unknown, generatedAt?: string): ServerStatus | null {
  if (!isRecord(raw)) return null
  return {
    ...(raw as ServerStatus),
    generated_at: generatedAt ?? toIsoTimestamp(raw.generated_at) ?? undefined,
    build: normalizeBuildIdentity(raw.build),
  }
}

export function mergeServerStatus(previous: ServerStatus | null, next: ServerStatus | null): ServerStatus | null {
  if (!next) return previous
  if (!previous) return next
  return {
    ...previous,
    ...next,
    build: next.build ?? previous.build,
    generated_at: next.generated_at ?? previous.generated_at,
  }
}

export function normalizeMdalStatus(value: unknown): MdalLoop['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'running' || raw === 'interrupted' || raw === 'completed' || raw === 'stopped' || raw === 'error') return raw
  if (raw.startsWith('error')) return 'error'
  return 'running'
}

export function normalizeMdalIteration(raw: unknown): MdalIterationRecord | null {
  if (!isRecord(raw)) return null
  const iteration = asNumber(raw.iteration)
  if (iteration == null) return null
  const metricBefore = asNumber(raw.metric_before) ?? 0
  const metricAfter = asNumber(raw.metric_after) ?? metricBefore
  const evidenceRaw = isRecord(raw.evidence) ? raw.evidence : null
  return {
    iteration,
    metric_before: metricBefore,
    metric_after: metricAfter,
    delta: asNumber(raw.delta) ?? (metricAfter - metricBefore),
    changes: asString(raw.changes) ?? '',
    failed_attempts: asString(raw.failed_attempts) ?? '',
    next_suggestion: asString(raw.next_suggestion) ?? '',
    elapsed_ms: asNumber(raw.elapsed_ms) ?? 0,
    cost_usd: asNumber(raw.cost_usd) ?? null,
    evidence: evidenceRaw
      ? {
          worker_engine: evidenceRaw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : 'api_tool_loop',
          worker_model: asString(evidenceRaw.worker_model) ?? '',
          tool_call_count: asNumber(evidenceRaw.tool_call_count) ?? 0,
          tool_names: asStringArray(evidenceRaw.tool_names) ?? [],
          session_id: asString(evidenceRaw.session_id) ?? '',
          evidence_status:
            evidenceRaw.evidence_status === 'legacy_unverified'
              ? 'legacy_unverified'
              : 'verified',
        }
      : null,
  }
}

export function normalizeMdalLoop(raw: unknown): MdalLoop | null {
  if (!isRecord(raw)) return null
  const loopId = asString(raw.loop_id)
  if (!loopId) return null
  const baseline = asNumber(raw.baseline_metric) ?? 0
  const history = Array.isArray(raw.history)
    ? raw.history.map(normalizeMdalIteration).filter((row): row is MdalIterationRecord => row !== null)
    : []
  const currentMetric =
    asNumber(raw.current_metric)
    ?? history[0]?.metric_after
    ?? baseline
  return {
    loop_id: loopId,
    profile: asString(raw.profile) ?? 'unknown',
    status: normalizeMdalStatus(raw.status),
    strict_mode: typeof raw.strict_mode === 'boolean' ? raw.strict_mode : undefined,
    error_message: asString(raw.error_message) ?? asString(raw.error_reason) ?? null,
    stop_reason: asString(raw.stop_reason) ?? asString(raw.reason) ?? null,
    current_iteration: asNumber(raw.current_iteration) ?? history[0]?.iteration ?? 0,
    max_iterations: asNumber(raw.max_iterations) ?? 0,
    baseline_metric: baseline,
    current_metric: currentMetric,
    target: asString(raw.target) ?? '',
    stagnation_streak: asNumber(raw.stagnation_streak) ?? 0,
    stagnation_limit: asNumber(raw.stagnation_limit) ?? 0,
    elapsed_seconds: asNumber(raw.elapsed_seconds) ?? 0,
    updated_at: toIsoTimestamp(raw.updated_at) ?? null,
    stopped_at: toIsoTimestamp(raw.stopped_at) ?? null,
    execution_mode: raw.execution_mode === 'worker_spawn' ? 'worker_spawn' : undefined,
    worker_engine: raw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : null,
    worker_model: asString(raw.worker_model) ?? null,
    evidence_policy:
      raw.evidence_policy === 'hard' || raw.evidence_policy === 'legacy'
        ? raw.evidence_policy
        : undefined,
    latest_tool_call_count: asNumber(raw.latest_tool_call_count) ?? 0,
    latest_tool_names: asStringArray(raw.latest_tool_names) ?? [],
    session_id: asString(raw.session_id) ?? null,
    evidence_status:
      raw.evidence_status === 'legacy_unverified'
        ? 'legacy_unverified'
        : raw.evidence_status === 'verified'
          ? 'verified'
          : null,
    durability:
      raw.durability === 'persistent_backend' || raw.durability === 'memory_only'
        ? raw.durability
        : undefined,
    persistence_backend:
      raw.persistence_backend === 'filesystem'
      || raw.persistence_backend === 'postgres'
      || raw.persistence_backend === 'memory'
        ? raw.persistence_backend
        : undefined,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    history,
  }
}
