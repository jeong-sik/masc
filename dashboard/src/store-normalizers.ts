import { isRecord, asString, asNumber, asBoolean, asStringArray, toIsoTimestamp } from './components/common/normalize'
import {
  parseTaskStatus,
  parseExecutionTone,
  parseSignalTruth,
  parseEvidenceSource,
} from './lib/core-parsers'
import { normalizeKeeperTrust } from './keeper-store-normalize'
import { normalizeStopCause } from './lib/stop-cause'
import { parseAgentStatus } from './lib/agent-status'
import type {
  Agent, Task, Message, ServerStatus,
  DashboardExecutionSummary, DashboardExecutionHandoff,
  DashboardExecutionQueueItem, DashboardExecutionSessionBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardCdalHealth,
  DashboardCdalProofCompleteness,
  DashboardCdalProofStoreHealth,
  DashboardCdalTaskScopeHealth,
  DashboardFleetPressureHealth,
  DashboardFleetSafetyHealth,
  DashboardBlockerClassObject,
  DashboardBlockerInfo,
  DashboardKeeperReactionLedgerHealth,
  DashboardKeeperReactionLedgerPendingKeeper,
  DashboardPausedKeeperDetail,
  DashboardPausedKeeperReadError,
  DashboardPausedKeepersHealth,
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
  // Backend aliases that normalize to canonical AgentStatus tokens.
  if (raw === 'in_progress' || raw === 'claimed') return 'busy'
  if (raw === 'dead' || raw === 'left') return 'offline'
  // Canonical tokens — validated by parseAgentStatus SSOT.
  return parseAgentStatus(raw) ?? undefined
}

export function normalizeTaskStatus(value: unknown): Task['status'] {
  return parseTaskStatus(value)
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
  const workspace = asString(raw.workspace) ?? asString(raw.workspace_id) ?? asString(raw.channel) ?? asString(raw.channel_name)
  return {
    id: asString(raw.id),
    seq: asNumber(raw.seq),
    from,
    content,
    timestamp,
    type: asString(raw.type),
    workspace,
  }
}

export function normalizeExecutionTone(value: unknown): DashboardExecutionQueueItem['severity'] {
  return parseExecutionTone(value)
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
  const runtimeTrust = normalizeKeeperTrust(raw.runtime_trust ?? raw.trust)
  const terminalReason = runtimeTrust?.latest_terminal_reason ?? null
  const terminalReasonCode =
    asString(raw.terminal_reason_code) ?? terminalReason?.code ?? null
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
    terminal_reason_code: terminalReasonCode,
    stop_cause: normalizeStopCause({
      stop_cause: raw.stop_cause,
      runtime_blocker_class: asString(raw.runtime_blocker_class) ?? asString(raw.runtime_blocker) ?? null,
      runtime_blocker_summary: asString(raw.runtime_blocker_summary) ?? null,
      terminal_reason_code: terminalReasonCode,
      terminal_reason_summary: terminalReason?.summary ?? null,
      terminal_reason_severity: terminalReason?.severity ?? null,
      terminal_reason_next_action: terminalReason?.next_action ?? null,
      attention_reason: asString(raw.attention_reason) ?? null,
      next_action: asString(raw.next_human_action) ?? runtimeTrust?.latest_next_action ?? null,
    }),
    runtime_trust: runtimeTrust,
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
  const namespace = asString(raw.namespace) ?? null
  return {
    session_id: sessionId,
    goal,
    namespace,
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
  const signalTruth = parseSignalTruth(asString(raw.signal_truth))
  const evidenceSource = parseEvidenceSource(asString(raw.evidence_source))
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
  const runtimeAuthoring = normalizeDashboardConfigResolutionItem(raw.runtime_authoring)
  const runtime = normalizeDashboardConfigResolutionItem(raw.runtime)
  const prompts = normalizeDashboardConfigResolutionItem(raw.prompts)
  const keepers = normalizeDashboardConfigResolutionItem(raw.keepers)
  const personas = normalizeDashboardConfigResolutionItem(raw.personas)
  if (!status || !configRoot || !runtimeAuthoring || !runtime || !prompts || !keepers || !personas) return null
  return {
    status: status as DashboardConfigResolution['status'],
    warnings: asStringArray(raw.warnings),
    config_root: configRoot,
    runtime_authoring: runtimeAuthoring,
    runtime,
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
  const reactiveMaxIdle = intField('reactive_max_idle_turns')
  const autonomousMaxIdle = intField('autonomous_max_idle_turns')
  const turnTimeout = floatField('turn_timeout_sec')
  const admissionWait = floatField('admission_wait_timeout_sec')
  const oasTimeoutOverride = optFloatField('oas_timeout_override_sec')
  const oasTimeoutPer1k = floatField('oas_timeout_per_1k')
  const oasTimeoutPerTurn = floatField('oas_timeout_per_turn')
  if (!bootstrap || !reactiveMaxIdle || !autonomousMaxIdle || !turnTimeout
    || !admissionWait || !oasTimeoutPer1k || !oasTimeoutPerTurn) return null
  return {
    bootstrap_max_active_keepers: bootstrap,
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
  generatedAt?: string,
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
    generated_at: generatedAt ?? toIsoTimestamp(raw.generated_at) ?? null,
    status,
    warnings: asStringArray(raw.warnings),
    base_path: basePath,
    workspace_path: workspacePath,
    resolved_base_path: resolvedBasePath,
    data_root: dataRoot,
    prompt_markdown_dir: promptMarkdownDir,
    server_repo_path: normalizeDashboardConfigResolutionItem(raw.server_repo_path),
    server_repo_git_commit: asString(raw.server_repo_git_commit) ?? null,
    workspace_git_commit: asString(raw.workspace_git_commit) ?? null,
    resolved_base_git_commit: asString(raw.resolved_base_git_commit) ?? null,
    source_mismatch: asBoolean(raw.source_mismatch) ?? false,
    server_workspace_mismatch: asBoolean(raw.server_workspace_mismatch) ?? false,
    diagnostics: (Array.isArray(raw.diagnostics) ? raw.diagnostics : [])
      .map(normalizeDashboardRuntimeDiagnostic)
      .filter((item): item is DashboardRuntimeDiagnostic => item !== null),
    build,
    keeper_runtime: normalizeKeeperRuntimeResolved(raw.keeper_runtime),
    fleet_safety: normalizeDashboardFleetSafetyHealth(raw),
    fd_accountant: normalizeDashboardFdAccountant(raw.fd_accountant),
    cdal: normalizeDashboardCdalHealth(raw.cdal),
  }
}

function normalizeDashboardFdAccountant(raw: unknown): DashboardRuntimeResolution['fd_accountant'] {
  if (!isRecord(raw)) return null
  const fdOpen = asNumber(raw.fd_open)
  const fdLimit = asNumber(raw.fd_limit)
  const pressureActive = asBoolean(raw.pressure_active)
  if (fdOpen == null && fdLimit == null && pressureActive == null) return null
  return {
    fd_open: fdOpen ?? null,
    fd_limit: fdLimit ?? null,
    pressure_active: pressureActive ?? null,
  }
}

function normalizeDashboardBlockerClass(raw: unknown): DashboardBlockerInfo['klass'] {
  const name = asString(raw)
  if (name) return name
  if (!isRecord(raw)) return null
  const objectName = asString(raw.name)
  if (!objectName) return null
  const result: DashboardBlockerClassObject = { name: objectName }
  if ('reason' in raw) result.reason = raw.reason
  return result
}

function normalizeDashboardBlockerInfo(raw: unknown): DashboardBlockerInfo | null {
  if (!isRecord(raw)) return null
  const klass = normalizeDashboardBlockerClass(raw.klass)
  const detail = asString(raw.detail) ?? null
  if (klass == null && detail == null) return null
  return { klass, detail }
}

function normalizeDashboardPausedKeeperDetail(raw: unknown): DashboardPausedKeeperDetail | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    autoboot_enabled: asBoolean(raw.autoboot_enabled) ?? null,
    pause_kind: asString(raw.pause_kind) ?? null,
    auto_resume_after_sec: asNumber(raw.auto_resume_after_sec) ?? null,
    persisted_auto_resume_after_sec: asNumber(raw.persisted_auto_resume_after_sec) ?? null,
    auto_resume_source: asString(raw.auto_resume_source) ?? null,
    paused_elapsed_sec: asNumber(raw.paused_elapsed_sec) ?? null,
    auto_resume_remaining_sec: asNumber(raw.auto_resume_remaining_sec) ?? null,
    last_blocker: normalizeDashboardBlockerInfo(raw.last_blocker),
    missing_pause_root_cause: asBoolean(raw.missing_pause_root_cause) ?? null,
  }
}

function normalizeDashboardPausedKeeperReadError(raw: unknown): DashboardPausedKeeperReadError | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const error = asString(raw.error)
  if (!keeper || !error) return null
  return { keeper, error }
}

function normalizeDashboardPausedKeepersHealth(raw: unknown): DashboardPausedKeepersHealth | null {
  if (!isRecord(raw)) return null
  const details = (Array.isArray(raw.details) ? raw.details : [])
    .map(normalizeDashboardPausedKeeperDetail)
    .filter((item): item is DashboardPausedKeeperDetail => item !== null)
  const readErrors = (Array.isArray(raw.read_errors) ? raw.read_errors : [])
    .map(normalizeDashboardPausedKeeperReadError)
    .filter((item): item is DashboardPausedKeeperReadError => item !== null)
  const names = asStringArray(raw.names)
  const runningNames = asStringArray(raw.running_names)
  const durableNames = asStringArray(raw.durable_names)
  const autobootEnabledNames = asStringArray(raw.autoboot_enabled_names)
  const count = asNumber(raw.count)
  const runningCount = asNumber(raw.running_count)
  const durableCount = asNumber(raw.durable_count)
  const autobootEnabledCount = asNumber(raw.autoboot_enabled_count)
  const readErrorCount = asNumber(raw.read_error_count)
  if (
    count == null
    && runningCount == null
    && durableCount == null
    && autobootEnabledCount == null
    && readErrorCount == null
    && names.length === 0
    && runningNames.length === 0
    && durableNames.length === 0
    && autobootEnabledNames.length === 0
    && details.length === 0
    && readErrors.length === 0
  ) {
    return null
  }
  return {
    count: count ?? null,
    names,
    running_count: runningCount ?? null,
    running_names: runningNames,
    durable_count: durableCount ?? null,
    durable_names: durableNames,
    autoboot_enabled_count: autobootEnabledCount ?? null,
    autoboot_enabled_names: autobootEnabledNames,
    details,
    read_error_count: readErrorCount ?? null,
    read_errors: readErrors,
  }
}

function normalizeDashboardFleetPressureHealth(raw: unknown): DashboardFleetPressureHealth | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status) ?? asString(raw.state) ?? null
  const reason = asString(raw.reason) ?? asString(raw.message) ?? null
  const blocker = asString(raw.blocker) ?? null
  const admissionBlocked = asBoolean(raw.admission_blocked)
    ?? asBoolean(raw.admission_blocks)
    ?? null
  const admissionBlockedKeepers = asNumber(raw.admission_blocked_keepers)
    ?? asNumber(raw.admission_blocked_count)
    ?? null
  const blockedKeepers = asNumber(raw.blocked_keepers)
    ?? asNumber(raw.keepers_blocked)
    ?? null
  const blockedCount = asNumber(raw.blocked_count)
    ?? asNumber(raw.blocked)
    ?? null
  const bootableKeeperCount = asNumber(raw.bootable_keeper_count)
  const runningKeeperFiberCount = asNumber(raw.running_keeper_fiber_count)
  const healthyRunningKeeperFiberCount = asNumber(raw.healthy_running_keeper_fiber_count)
  const failingKeeperFiberCount = asNumber(raw.failing_keeper_fiber_count)
  const executableKeeperFiberCount = asNumber(raw.executable_keeper_fiber_count)
  const minimumRunningFibers = asNumber(raw.minimum_running_fibers)
  const noRunningFibers = asBoolean(raw.no_running_fibers)
  const noExecutableKeeperFibers = asBoolean(raw.no_executable_keeper_fibers)
  const lowRunningFiberMargin = asBoolean(raw.low_running_fiber_margin)
  const reactionCapacityBelowTarget = asBoolean(raw.reaction_capacity_below_target)
  const reactionCapacityShortfallCount = asNumber(raw.reaction_capacity_shortfall_count)
  const executableReactionCapacityBelowTarget = asBoolean(raw.executable_reaction_capacity_below_target)
  const executableReactionCapacityShortfallCount = asNumber(raw.executable_reaction_capacity_shortfall_count)
  const pausedKeeperCount = asNumber(raw.paused_keeper_count)
  const autobootEnabledKeeperCount = asNumber(raw.autoboot_enabled_keeper_count)
  const pausedAutobootEnabledKeeperCount = asNumber(raw.paused_autoboot_enabled_keeper_count)
  const effectiveReactionCapacityCount = asNumber(raw.effective_reaction_capacity_count)
  const executableReactionCapacityCount = asNumber(raw.executable_reaction_capacity_count)
  const targetReactionCapacityCount = asNumber(raw.target_reaction_capacity_count)
  const operatorActionRequired = asBoolean(raw.operator_action_required)
  if (
    status == null
    && reason == null
    && blocker == null
    && admissionBlocked == null
    && admissionBlockedKeepers == null
    && blockedKeepers == null
    && blockedCount == null
    && bootableKeeperCount == null
    && runningKeeperFiberCount == null
    && healthyRunningKeeperFiberCount == null
    && failingKeeperFiberCount == null
    && executableKeeperFiberCount == null
    && minimumRunningFibers == null
    && noRunningFibers == null
    && noExecutableKeeperFibers == null
    && lowRunningFiberMargin == null
    && reactionCapacityBelowTarget == null
    && reactionCapacityShortfallCount == null
    && executableReactionCapacityBelowTarget == null
    && executableReactionCapacityShortfallCount == null
    && pausedKeeperCount == null
    && autobootEnabledKeeperCount == null
    && pausedAutobootEnabledKeeperCount == null
    && effectiveReactionCapacityCount == null
    && executableReactionCapacityCount == null
    && targetReactionCapacityCount == null
    && operatorActionRequired == null
  ) {
    return null
  }
  return {
    status,
    reason,
    blocker,
    admission_blocked: admissionBlocked,
    admission_blocked_keepers: admissionBlockedKeepers,
    blocked_keepers: blockedKeepers,
    blocked_count: blockedCount,
    bootable_keeper_count: bootableKeeperCount ?? null,
    running_keeper_fiber_count: runningKeeperFiberCount ?? null,
    healthy_running_keeper_fiber_count: healthyRunningKeeperFiberCount ?? null,
    failing_keeper_fiber_count: failingKeeperFiberCount ?? null,
    executable_keeper_fiber_count: executableKeeperFiberCount ?? null,
    minimum_running_fibers: minimumRunningFibers ?? null,
    no_running_fibers: noRunningFibers ?? null,
    no_executable_keeper_fibers: noExecutableKeeperFibers ?? null,
    low_running_fiber_margin: lowRunningFiberMargin ?? null,
    reaction_capacity_below_target: reactionCapacityBelowTarget ?? null,
    reaction_capacity_shortfall_count: reactionCapacityShortfallCount ?? null,
    executable_reaction_capacity_below_target: executableReactionCapacityBelowTarget ?? null,
    executable_reaction_capacity_shortfall_count: executableReactionCapacityShortfallCount ?? null,
    paused_keeper_count: pausedKeeperCount ?? null,
    autoboot_enabled_keeper_count: autobootEnabledKeeperCount ?? null,
    paused_autoboot_enabled_keeper_count: pausedAutobootEnabledKeeperCount ?? null,
    effective_reaction_capacity_count: effectiveReactionCapacityCount ?? null,
    executable_reaction_capacity_count: executableReactionCapacityCount ?? null,
    target_reaction_capacity_count: targetReactionCapacityCount ?? null,
    operator_action_required: operatorActionRequired ?? null,
  }
}

function normalizeDashboardKeeperReactionLedgerPendingKeeper(
  raw: unknown,
): DashboardKeeperReactionLedgerPendingKeeper | null {
  if (!isRecord(raw)) return null
  const keeperName = asString(raw.keeper_name)
  const pendingStimulusCount = asNumber(raw.pending_stimulus_count)
  if (!keeperName || pendingStimulusCount == null) return null
  return {
    keeper_name: keeperName,
    pending_stimulus_count: pendingStimulusCount,
    pending_stimulus_ids: asStringArray(raw.pending_stimulus_ids),
  }
}

function normalizeDashboardKeeperReactionLedgerHealth(
  raw: unknown,
): DashboardKeeperReactionLedgerHealth | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status) ?? null
  const operatorActionRequired = asBoolean(raw.operator_action_required) ?? null
  const keeperCount = asNumber(raw.keeper_count)
  const rowCount = asNumber(raw.row_count)
  const stimulusCount = asNumber(raw.stimulus_count)
  const reactionCount = asNumber(raw.reaction_count)
  const turnStartedCount = asNumber(raw.turn_started_count)
  const stimulusConsumedCount = asNumber(raw.stimulus_consumed_count)
  const cursorAckCount = asNumber(raw.cursor_ack_count)
  const executionReceiptCount = asNumber(raw.execution_receipt_count)
  const terminalReasonCount = asNumber(raw.terminal_reason_count)
  const operatorEscalationCount = asNumber(raw.operator_escalation_count)
  const unknownReactionCount = asNumber(raw.unknown_reaction_count)
  const cursorSweptStimulusCount = asNumber(raw.cursor_swept_stimulus_count)
  const legacyCursorSweptStimulusCount = asNumber(raw.legacy_cursor_swept_stimulus_count)
  const pendingStimulusCount = asNumber(raw.pending_stimulus_count)
  const readErrorCount = asNumber(raw.read_error_count)
  const pendingByKeeper = (Array.isArray(raw.pending_by_keeper) ? raw.pending_by_keeper : [])
    .map(normalizeDashboardKeeperReactionLedgerPendingKeeper)
    .filter((item): item is DashboardKeeperReactionLedgerPendingKeeper => item !== null)
  if (
    status == null
    && operatorActionRequired == null
    && keeperCount == null
    && rowCount == null
    && stimulusCount == null
    && reactionCount == null
    && turnStartedCount == null
    && stimulusConsumedCount == null
    && cursorAckCount == null
    && executionReceiptCount == null
    && terminalReasonCount == null
    && operatorEscalationCount == null
    && unknownReactionCount == null
    && cursorSweptStimulusCount == null
    && legacyCursorSweptStimulusCount == null
    && pendingStimulusCount == null
    && readErrorCount == null
    && pendingByKeeper.length === 0
  ) {
    return null
  }
  return {
    status,
    operator_action_required: operatorActionRequired,
    keeper_count: keeperCount ?? null,
    row_count: rowCount ?? null,
    stimulus_count: stimulusCount ?? null,
    reaction_count: reactionCount ?? null,
    turn_started_count: turnStartedCount ?? null,
    stimulus_consumed_count: stimulusConsumedCount ?? null,
    cursor_ack_count: cursorAckCount ?? null,
    execution_receipt_count: executionReceiptCount ?? null,
    terminal_reason_count: terminalReasonCount ?? null,
    operator_escalation_count: operatorEscalationCount ?? null,
    unknown_reaction_count: unknownReactionCount ?? null,
    cursor_swept_stimulus_count: cursorSweptStimulusCount ?? null,
    legacy_cursor_swept_stimulus_count: legacyCursorSweptStimulusCount ?? null,
    pending_stimulus_count: pendingStimulusCount ?? null,
    read_error_count: readErrorCount ?? null,
    pending_by_keeper: pendingByKeeper,
  }
}

function normalizeDashboardFleetSafetyHealth(raw: Record<string, unknown>): DashboardFleetSafetyHealth | null {
  const keeperFibers = asNumber(raw.keeper_fibers)
  const pausedKeepers = asNumber(raw.paused_keepers)
  const pausedKeepersHealth = normalizeDashboardPausedKeepersHealth(raw.paused_keepers_health)
  const noFibers = asBoolean(raw.keeper_fleet_no_fibers)
  const fdPressure = normalizeDashboardFleetPressureHealth(raw.keeper_fd_pressure)
  const fleetSafety = normalizeDashboardFleetPressureHealth(raw.keeper_fleet_safety)
  const reactionLedger = normalizeDashboardKeeperReactionLedgerHealth(raw.keeper_reaction_ledger)
  if (
    keeperFibers == null
    && pausedKeepers == null
    && pausedKeepersHealth == null
    && noFibers == null
    && fdPressure == null
    && fleetSafety == null
    && reactionLedger == null
  ) {
    return null
  }
  return {
    keeper_fibers: keeperFibers ?? null,
    paused_keepers: pausedKeepers ?? null,
    paused_keepers_health: pausedKeepersHealth,
    keeper_fleet_no_fibers: noFibers ?? null,
    keeper_fd_pressure: fdPressure,
    keeper_fleet_safety: fleetSafety,
    keeper_reaction_ledger: reactionLedger,
  }
}

function normalizeDashboardCdalProofCompleteness(raw: unknown): DashboardCdalProofCompleteness | null {
  if (!isRecord(raw)) return null
  const incomplete = asNumber(raw.incomplete_run_dirs)
  const stale = asNumber(raw.stale_incomplete_run_dirs)
  const terminal = asNumber(raw.terminal_incomplete_run_dirs)
  const samples = asStringArray(raw.sample_stale_incomplete_run_ids)
  const terminalSamples = asStringArray(raw.sample_terminal_incomplete_run_ids)
  if (incomplete == null && stale == null && terminal == null && samples.length === 0 && terminalSamples.length === 0) {
    return null
  }
  return {
    scan_limit: asNumber(raw.scan_limit) ?? null,
    run_dir_entries_seen: asNumber(raw.run_dir_entries_seen) ?? null,
    scan_truncated: asBoolean(raw.scan_truncated) ?? null,
    run_dirs_scanned: asNumber(raw.run_dirs_scanned) ?? null,
    completed_run_dirs: asNumber(raw.completed_run_dirs) ?? null,
    incomplete_run_dirs: incomplete ?? null,
    stale_incomplete_run_dirs: stale ?? null,
    terminal_incomplete_run_dirs: terminal ?? null,
    missing_manifest_run_dirs: asNumber(raw.missing_manifest_run_dirs) ?? null,
    missing_contract_run_dirs: asNumber(raw.missing_contract_run_dirs) ?? null,
    stale_incomplete_grace_seconds: asNumber(raw.stale_incomplete_grace_seconds) ?? null,
    sample_stale_incomplete_run_ids: samples,
    sample_terminal_incomplete_run_ids: terminalSamples,
  }
}

function normalizeDashboardCdalProofStoreHealth(raw: unknown): DashboardCdalProofStoreHealth | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status) ?? null
  const completeness = normalizeDashboardCdalProofCompleteness(raw.completeness)
  if (status == null && completeness == null) return null
  return {
    root: asString(raw.root) ?? null,
    proofs_dir: asString(raw.proofs_dir) ?? null,
    exists: asBoolean(raw.exists) ?? null,
    latest_activity_at: asString(raw.latest_activity_at) ?? null,
    latest_activity_unix: asNumber(raw.latest_activity_unix) ?? null,
    age_seconds: asNumber(raw.age_seconds) ?? null,
    status,
    completeness,
  }
}

function normalizeDashboardCdalTaskScopeHealth(raw: unknown): DashboardCdalTaskScopeHealth | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status) ?? null
  const recentRows = asNumber(raw.recent_rows)
  const missingRows = asNumber(raw.missing_task_scope_rows)
  const legacyRows = asNumber(raw.legacy_unscoped_rows)
  const currentMissingRows = asNumber(raw.current_writer_missing_task_scope_rows)
  if (status == null && recentRows == null && missingRows == null && legacyRows == null && currentMissingRows == null) {
    return null
  }
  return {
    status,
    recent_limit: asNumber(raw.recent_limit) ?? null,
    recent_rows: recentRows ?? null,
    task_id_rows: asNumber(raw.task_id_rows) ?? null,
    missing_task_scope_rows: missingRows ?? null,
    legacy_unscoped_rows: legacyRows ?? null,
    current_writer_missing_task_scope_rows: currentMissingRows ?? null,
    missing_task_scope: asBoolean(raw.missing_task_scope) ?? null,
    partial_task_scope: asBoolean(raw.partial_task_scope) ?? null,
    current_writer_missing_task_scope: asBoolean(raw.current_writer_missing_task_scope) ?? null,
  }
}

function normalizeDashboardCdalHealth(raw: unknown): DashboardCdalHealth | null {
  if (!isRecord(raw)) return null
  const writerStatus = asString(raw.writer_status) ?? null
  const operatorActionRequired = asBoolean(raw.operator_action_required) ?? null
  const proofStore = normalizeDashboardCdalProofStoreHealth(raw.proof_store)
  const taskScope = normalizeDashboardCdalTaskScopeHealth(raw.task_scope)
  const proofStorePathDrift = asBoolean(raw.proof_store_path_drift) ?? null
  if (
    writerStatus == null
    && operatorActionRequired == null
    && proofStorePathDrift == null
    && proofStore == null
    && taskScope == null
  ) {
    return null
  }
  return {
    writer_status: writerStatus,
    operator_action_required: operatorActionRequired,
    proof_store_path_drift: proofStorePathDrift,
    proof_store: proofStore,
    task_scope: taskScope,
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

function messageIdentityKey(message: Message): string {
  if (typeof message.seq === 'number' && Number.isFinite(message.seq)) {
    return JSON.stringify(['seq', message.seq])
  }
  if (message.id) return JSON.stringify(['id', message.id])
  return JSON.stringify([
    'fallback',
    message.timestamp ?? '',
    message.from ?? '',
    message.content,
    message.type ?? '',
    message.workspace ?? '',
  ])
}

function stableValueEqual(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false
    if (left.length !== right.length) return false
    return left.every((value, index) => stableValueEqual(value, right[index]))
  }
  if (isRecord(left) || isRecord(right)) {
    if (!isRecord(left) || !isRecord(right)) return false
    const keys = new Set([...Object.keys(left), ...Object.keys(right)])
    for (const key of keys) {
      if (!stableValueEqual(left[key], right[key])) return false
    }
    return true
  }
  return false
}

function messageEqual(left: Message, right: Message): boolean {
  return stableValueEqual(left, right)
}

export function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  if (incoming.length === 0) return current
  const byKey = new Map<string, Message>()
  for (const message of current) {
    byKey.set(messageIdentityKey(message), message)
  }
  for (const message of incoming) {
    const key = messageIdentityKey(message)
    const previous = byKey.get(key)
    byKey.set(key, previous && messageEqual(previous, message) ? previous : message)
  }
  const merged = [...byKey.values()]
    .sort((a, b) => messageSortKey(a) - messageSortKey(b))
    .slice(-500)
  if (merged.length === current.length && merged.every((message, index) => message === current[index])) {
    return current
  }
  return merged
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
