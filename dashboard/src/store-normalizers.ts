import { isRecord, asString, asNumber, asBoolean, asStringArray, toIsoTimestamp } from './components/common/normalize'
import { normalizeKeeperTrust } from './keeper-store-normalize'
import type {
  Agent, Task, Message, ServerStatus,
  DashboardExecutionSummary, DashboardExecutionHandoff,
  DashboardExecutionQueueItem, DashboardExecutionSessionBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeResolution,
  KeeperRuntimeResolved,
  KeeperRuntimeField,
  KeeperRuntimeSource,
  DashboardShellMetaCognitionBelief,
  DashboardShellMetaCognitionDesire,
  DashboardShellMetaCognitionSummary,
  DashboardShellMetaCognitionTension,
  OperatorAttentionItem, OperatorRecommendedAction,
} from './types'

// --- Data fetchers ---

export function normalizeAgentStatus(value: unknown): Agent['status'] {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : ''
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
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : ''
  if (
    raw === 'todo'
    || raw === 'in_progress'
    || raw === 'claimed'
    || raw === 'awaiting_verification'
    || raw === 'done'
    || raw === 'cancelled'
  ) {
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
    keeper_name: asString(raw.keeper_name) ?? null,
    keeper_id: asString(raw.keeper_id) ?? null,
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
  const worktree = isRecord(raw.worktree)
    ? {
        branch: asString(raw.worktree.branch, ''),
        path: asString(raw.worktree.path, ''),
        git_root: asString(raw.worktree.git_root, ''),
        repo_name: asString(raw.worktree.repo_name, ''),
      }
    : null
  const contract = isRecord(raw.contract)
    ? {
        strict: asBoolean(raw.contract.strict),
        completion_contract: asStringArray(raw.contract.completion_contract),
        required_evidence: asStringArray(raw.contract.required_evidence),
        inspect_gate_evidence: asStringArray(raw.contract.inspect_gate_evidence),
        verify_gate_evidence: asStringArray(raw.contract.verify_gate_evidence),
        links: isRecord(raw.contract.links)
          ? {
              operation_id: asString(raw.contract.links.operation_id) ?? null,
              session_id: asString(raw.contract.links.session_id) ?? null,
              autoresearch_loop_id: asString(raw.contract.links.autoresearch_loop_id) ?? null,
            }
          : null,
      }
    : null
  const handoffContext = isRecord(raw.handoff_context)
    ? {
        summary: asString(raw.handoff_context.summary, ''),
        reason: asString(raw.handoff_context.reason) ?? null,
        next_step: asString(raw.handoff_context.next_step) ?? null,
        failure_mode: asString(raw.handoff_context.failure_mode) ?? null,
        evidence_refs: asStringArray(raw.handoff_context.evidence_refs),
        updated_at: asString(raw.handoff_context.updated_at) ?? null,
        updated_by: asString(raw.handoff_context.updated_by) ?? null,
      }
    : null
  const executionLinks = isRecord(raw.execution_links)
    ? {
        operation_id: asString(raw.execution_links.operation_id) ?? null,
        session_id: asString(raw.execution_links.session_id) ?? null,
        autoresearch_loop_id: asString(raw.execution_links.autoresearch_loop_id) ?? null,
      }
    : null
  return {
    id,
    title,
    goal_id: asString(raw.goal_id) ?? null,
    status: normalizeTaskStatus(raw.status),
    priority: asNumber(raw.priority),
    assignee: asString(raw.assignee),
    assignee_kind: asString(raw.assignee_kind) ?? null,
    description: asString(raw.description),
    worktree,
    created_at: asString(raw.created_at),
    updated_at: asString(raw.updated_at),
    completed_at: asString(raw.completed_at),
    contract,
    handoff_context: handoffContext,
    execution_links: executionLinks,
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
  if (!id || !summary || !targetType || !targetId || (kind !== 'session' && kind !== 'operation' && kind !== 'keeper')) {
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
    attention_reason: asString(raw.attention_reason) ?? null,
    next_human_action: asString(raw.next_human_action) ?? null,
    terminal_reason_code: asString(raw.terminal_reason_code) ?? null,
    runtime_trust: normalizeKeeperTrust(raw.runtime_trust ?? raw.trust),
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
  const namespace = asString(raw.namespace) ?? asString(raw.room) ?? null
  return {
    session_id: sessionId,
    goal,
    namespace,
    // Keep `room` as a pure compatibility alias during namespace flattening.
    room: namespace,
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
    keeper_name: asString(raw.keeper_name) ?? null,
    keeper_id: asString(raw.keeper_id) ?? null,
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
    keeper_id: asString(raw.keeper_id) ?? null,
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
    allowed_tool_count: asNumber(raw.allowed_tool_count) ?? null,
    allowed_tool_preview: asStringArray(raw.allowed_tool_preview) ?? [],
    latest_tool_names: asStringArray(raw.latest_tool_names) ?? [],
    latest_tool_call_count: asNumber(raw.latest_tool_call_count) ?? null,
    tool_audit_source: asString(raw.tool_audit_source) ?? null,
    tool_audit_at: asString(raw.tool_audit_at) ?? null,
    last_proactive_preview: asString(raw.last_proactive_preview) ?? null,
    continuity_summary: asString(raw.continuity_summary) ?? null,
    skill_route_summary: asString(raw.skill_route_summary) ?? null,
  }
}

export function normalizeShellMetaCognitionBelief(
  raw: unknown,
): DashboardShellMetaCognitionBelief | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const claim = asString(raw.claim)
  const status = asString(raw.status)
  if (!id || !claim || !status) return null
  return {
    id,
    claim,
    status,
    confidence: asNumber(raw.confidence) ?? null,
    support_agent_count: asNumber(raw.support_agent_count) ?? null,
    challenge_agent_count: asNumber(raw.challenge_agent_count) ?? null,
  }
}

export function normalizeShellMetaCognitionTension(
  raw: unknown,
): DashboardShellMetaCognitionTension | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const topic = asString(raw.topic)
  if (!id || !topic) return null
  return {
    id,
    topic,
    kind: asString(raw.kind) ?? null,
    severity: asString(raw.severity) ?? null,
    recurrence_count: asNumber(raw.recurrence_count) ?? null,
    needs_operator: asBoolean(raw.needs_operator) ?? false,
  }
}

export function normalizeShellMetaCognitionDesire(
  raw: unknown,
): DashboardShellMetaCognitionDesire | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const desiredState = asString(raw.desired_state)
  if (!id || !desiredState) return null
  return {
    id,
    desired_state: desiredState,
    type: asString(raw.type) ?? null,
    actionability: asString(raw.actionability) ?? null,
    strength: asNumber(raw.strength) ?? null,
  }
}

export function normalizeShellMetaCognitionSummary(
  raw: unknown,
): DashboardShellMetaCognitionSummary | null {
  if (!isRecord(raw)) return null
  const stagnationScore = asNumber(raw.stagnation_score)
  if (stagnationScore == null) return null
  return {
    stagnation_score: stagnationScore,
    belief_count: asNumber(raw.belief_count) ?? 0,
    contested_belief_count: asNumber(raw.contested_belief_count) ?? 0,
    dominant_belief: normalizeShellMetaCognitionBelief(raw.dominant_belief),
    top_tension: normalizeShellMetaCognitionTension(raw.top_tension),
    top_desire: normalizeShellMetaCognitionDesire(raw.top_desire),
  }
}

export function normalizeDashboardConfigResolutionItem(
  raw: unknown,
): DashboardConfigResolutionItem | null {
  if (!isRecord(raw)) return null
  const path = asString(raw.path)
  const source = asString(raw.source)
  const exists = asBoolean(raw.exists)
  if (!path || !source || exists == null) return null
  return { path, source, exists }
}

export function normalizeDashboardConfigResolution(
  raw: unknown,
): DashboardConfigResolution | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status)
  const configRoot = normalizeDashboardConfigResolutionItem(raw.config_root)
  const cascadeAuthoring = normalizeDashboardConfigResolutionItem(raw.cascade_authoring)
  const cascade = normalizeDashboardConfigResolutionItem(raw.cascade)
  const prompts = normalizeDashboardConfigResolutionItem(raw.prompts)
  const keepers = normalizeDashboardConfigResolutionItem(raw.keepers)
  const personas = normalizeDashboardConfigResolutionItem(raw.personas)
  if (!status || !configRoot || !cascadeAuthoring || !cascade || !prompts || !keepers || !personas) return null
  return {
    status: status as DashboardConfigResolution['status'],
    warnings: asStringArray(raw.warnings),
    config_root: configRoot,
    cascade_authoring: cascadeAuthoring,
    cascade,
    prompts,
    keepers,
    personas,
  }
}

export function normalizeDashboardRuntimeDiagnostic(
  raw: unknown,
): DashboardRuntimeDiagnostic | null {
  if (!isRecord(raw)) return null
  const ts = asString(raw.ts)
  const kind = asString(raw.kind)
  const message = asString(raw.message)
  if (!ts || !kind || !message) return null
  return {
    ts,
    kind,
    signal: asString(raw.signal),
    message,
  }
}

const _MISSING = Symbol('missing')

function normalizeKeeperRuntimeField<T>(
  raw: unknown,
  valueNormalize: (v: unknown) => T | typeof _MISSING,
): KeeperRuntimeField<T> | null {
  if (!isRecord(raw)) return null
  const value = valueNormalize(raw.value)
  if (value === _MISSING) return null
  const source = asString(raw.source)
  if (!source) return null
  const validSources: KeeperRuntimeSource[] = ['env', 'toml', 'default', 'derived']
  return {
    value: value as T,
    source: validSources.includes(source as KeeperRuntimeSource)
      ? (source as KeeperRuntimeSource) : 'default',
  }
}

function normalizeKeeperRuntimeResolved(raw: unknown): KeeperRuntimeResolved | null {
  if (!isRecord(raw)) return null
  const toNumber = (v: unknown): number | typeof _MISSING => {
    const n = asNumber(v)
    return n !== null && n !== undefined ? n : _MISSING
  }
  const intField = (key: string) => normalizeKeeperRuntimeField(
    (raw as Record<string, unknown>)[key], v => {
      const n = toNumber(v)
      return n === _MISSING ? _MISSING : Math.round(n as number)
    },
  )
  const floatField = (key: string) => normalizeKeeperRuntimeField(
    (raw as Record<string, unknown>)[key], toNumber,
  )
  const optFloatField = (key: string) => normalizeKeeperRuntimeField<number | null>(
    (raw as Record<string, unknown>)[key],
    v => v === null || v === undefined ? null : toNumber(v) === _MISSING ? _MISSING : (toNumber(v) as number),
  )
  const bootstrap = intField('bootstrap_max_active_keepers')
  const reactiveMaxTurns = intField('reactive_max_turns_per_call')
  const autonomousMaxTurns = intField('autonomous_max_turns_per_call')
  const reactiveMaxIdle = intField('reactive_max_idle_turns')
  const autonomousMaxIdle = intField('autonomous_max_idle_turns')
  const turnTimeout = floatField('turn_timeout_sec')
  const admissionWait = floatField('admission_wait_timeout_sec')
  const oasTimeoutOverride = optFloatField('oas_timeout_override_sec')
  const oasTimeoutPer1k = floatField('oas_timeout_per_1k')
  const oasTimeoutPerTurn = floatField('oas_timeout_per_turn')
  if (!bootstrap || !reactiveMaxTurns || !autonomousMaxTurns || !reactiveMaxIdle
    || !autonomousMaxIdle || !turnTimeout || !admissionWait || !oasTimeoutPer1k
    || !oasTimeoutPerTurn) return null
  return {
    bootstrap_max_active_keepers: bootstrap,
    reactive_max_turns_per_call: reactiveMaxTurns,
    autonomous_max_turns_per_call: autonomousMaxTurns,
    reactive_max_idle_turns: reactiveMaxIdle,
    autonomous_max_idle_turns: autonomousMaxIdle,
    turn_timeout_sec: turnTimeout,
    admission_wait_timeout_sec: admissionWait,
    oas_timeout_override_sec: oasTimeoutOverride as KeeperRuntimeField<number | null>,
    oas_timeout_per_1k: oasTimeoutPer1k,
    oas_timeout_per_turn: oasTimeoutPerTurn,
  }
}

export function normalizeDashboardRuntimeResolution(
  raw: unknown,
): DashboardRuntimeResolution | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status)
  const basePath = normalizeDashboardConfigResolutionItem(raw.base_path)
  const workspacePath = normalizeDashboardConfigResolutionItem(raw.workspace_path)
  const resolvedBasePath = normalizeDashboardConfigResolutionItem(raw.resolved_base_path)
  const dataRoot = normalizeDashboardConfigResolutionItem(raw.data_root)
  const promptMarkdownDir = normalizeDashboardConfigResolutionItem(raw.prompt_markdown_dir)
  const build = normalizeBuildIdentity(raw.build)
  if (!status || !basePath || !workspacePath || !resolvedBasePath || !dataRoot || !promptMarkdownDir || !build) {
    return null
  }
  return {
    status,
    warnings: asStringArray(raw.warnings),
    base_path: basePath,
    workspace_path: workspacePath,
    resolved_base_path: resolvedBasePath,
    data_root: dataRoot,
    prompt_markdown_dir: promptMarkdownDir,
    workspace_git_commit: asString(raw.workspace_git_commit) ?? null,
    resolved_base_git_commit: asString(raw.resolved_base_git_commit) ?? null,
    source_mismatch: asBoolean(raw.source_mismatch) ?? false,
    diagnostics: (Array.isArray(raw.diagnostics) ? raw.diagnostics : [])
      .map(normalizeDashboardRuntimeDiagnostic)
      .filter((item): item is DashboardRuntimeDiagnostic => item !== null),
    build,
    keeper_runtime: normalizeKeeperRuntimeResolved(raw.keeper_runtime),
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
