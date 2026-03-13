// MASC Dashboard — Centralized reactive state via @preact/signals
// SSE events and API responses update these signals;
// subscribing components re-render automatically.

import { signal, computed, type ReadonlySignal } from '@preact/signals'
import type {
  Agent,
  Task,
  Message,
  Keeper,
  BoardPost,
  ServerStatus,
  PerpetualStatus,
  TrpgState,
  BoardSortMode,
  KeeperLifecycleState,
  Goal,
  MdalLoop,
  MdalIterationRecord,
  DashboardSemanticsResponse,
  DashboardSemanticSurface,
  DashboardSemanticPanel,
  DashboardSemanticSurfaceId,
  DashboardExecutionHandoff,
  DashboardExecutionSummary,
  DashboardExecutionQueueItem,
  DashboardExecutionSessionBrief,
  DashboardExecutionOperationBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionLodgeTick,
  DashboardExecutionLodgeCheckin,
  DashboardExecutionContinuityBrief,
} from './types'
import {
  fetchDashboardExecution,
  fetchDashboardMemory,
  fetchDashboardPlanning,
  fetchDashboardSemantics,
  fetchDashboardShell,
  fetchMessagesList,
  fetchTrpgState,
} from './api'
import { journal } from './sse'
import { normalizeLodgeRuntimeStatus } from './keeper-runtime'
import {
  deriveLifecycleState,
  keeperFreshnessTs,
  normalizeKeepers,
} from './keeper-store-normalize'
import { buildAgentMotion, type AgentMotionSnapshot } from './components/common/agent-motion'
import { isRecord, asString, asNumber, asStringArray, toIsoTimestamp } from './components/common/normalize'

// --- Core state signals ---

export const agents = signal<Agent[]>([])
export const tasks = signal<Task[]>([])
export const messages = signal<Message[]>([])
export const keepers = signal<Keeper[]>([])
export const serverStatus = signal<ServerStatus | null>(null)
export const perpetualStatus = signal<PerpetualStatus | null>(null)
export const executionSummary = signal<DashboardExecutionSummary | null>(null)
export const executionQueue = signal<DashboardExecutionQueueItem[]>([])
export const executionSessionBriefs = signal<DashboardExecutionSessionBrief[]>([])
export const executionOperationBriefs = signal<DashboardExecutionOperationBrief[]>([])
export const executionWorkerSupportBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])
export const executionLodgeTick = signal<DashboardExecutionLodgeTick | null>(null)
export const executionLodgeCheckins = signal<DashboardExecutionLodgeCheckin[]>([])
export const executionContinuityBriefs = signal<DashboardExecutionContinuityBrief[]>([])
export const executionOfflineWorkerBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])

// --- Keeper heartbeat tracking (name -> last heartbeat timestamp ms) ---

export const keeperHeartbeats = signal<Map<string, number>>(new Map())

// --- Board state ---

export const boardPosts = signal<BoardPost[]>([])
export const boardSortMode = signal<BoardSortMode>('recent')
export const boardExcludeSystem = signal(true)

// --- TRPG state ---

export const trpgState = signal<TrpgState | null>(null)
export const trpgRoom = signal<string>('')

// --- Goals state ---

export const goals = signal<Goal[]>([])
export const goalsLoading = signal(false)

// --- MDAL state ---

export const mdalLoops = signal<Map<string, MdalLoop>>(new Map())
export const mdalSnapshotState = signal<'unknown' | 'idle' | 'ready' | 'error'>('unknown')
export const lastMdalError = signal<string | null>(null)

// --- Loading flags ---

export const dashboardLoading = signal(false)
export const boardLoading = signal(false)
export const trpgLoading = signal(false)
export const mdalLoading = signal(false)
export const dashboardSemantics = signal<DashboardSemanticsResponse | null>(null)
export const dashboardSemanticsLoading = signal(false)
export const dashboardSemanticsError = signal<string | null>(null)

// --- Refresh timestamps ---

export const lastDashboardRefreshAt = signal<string | null>(null)
export const lastBoardRefreshAt = signal<string | null>(null)
export const lastGoalsRefreshAt = signal<string | null>(null)
export const lastMdalRefreshAt = signal<string | null>(null)
export const lastDashboardSemanticsRefreshAt = signal<string | null>(null)

// --- Derived state ---

export const activeAgents: ReadonlySignal<Agent[]> = computed(() =>
  agents.value.filter(
    a =>
      a.status === 'active'
      || a.status === 'busy'
      || a.status === 'listening'
      || a.status === 'idle',
  )
)

export const tasksByStatus = computed(() => {
  const all = tasks.value
  return {
    todo: all.filter(t => t.status === 'todo'),
    inProgress: all.filter(t => t.status === 'in_progress' || t.status === 'claimed'),
    done: all.filter(t => t.status === 'done'),
  }
})

export const agentMotionMap: ReadonlySignal<Map<string, AgentMotionSnapshot>> = computed(() => {
  const map = new Map<string, AgentMotionSnapshot>()
  const taskList = tasks.value
  const messageList = messages.value
  const journalList = journal.value
  const boardPostList = boardPosts.value
  const keeperList = keepers.value
  for (const agent of agents.value) {
    map.set(
      agent.name.trim().toLowerCase(),
      buildAgentMotion(agent.name, taskList, messageList, journalList, {
        currentTask: agent.current_task,
        lastSeen: agent.last_seen,
        boardPosts: boardPostList,
        keepers: keeperList,
      }),
    )
  }
  return map
})

export const keeperLifecycles: ReadonlySignal<Map<string, KeeperLifecycleState>> = computed(() => {
  const map = new Map<string, KeeperLifecycleState>()
  for (const k of keepers.value) {
    const status = k.status?.toLowerCase() ?? ''
    if (status === 'offline' || status === 'inactive') {
      map.set(k.name, 'offline')
      continue
    }
    if (!k.metrics_series || k.metrics_series.length === 0) continue
    map.set(k.name, deriveLifecycleState(k))
  }
  return map
})

// Heartbeat staleness threshold (120 seconds)
const HEARTBEAT_STALE_MS = 120_000

export const staleKeepers: ReadonlySignal<Set<string>> = computed(() => {
  const now = Date.now()
  const stale = new Set<string>()
  const hb = keeperHeartbeats.value
  for (const k of keepers.value) {
    const lastTs = keeperFreshnessTs(k, hb)
    if (lastTs != null && (now - lastTs) > HEARTBEAT_STALE_MS) {
      stale.add(k.name)
    }
  }
  return stale
})

// --- Refresh orchestration ---

export function isDashboardRefreshEvent(eventType: string): boolean {
  return (
    eventType === 'dashboard_refresh'
    || eventType === 'masc/dashboard_refresh'
    || eventType.startsWith('goal_')
    || eventType.startsWith('masc/goal_')
    || eventType.startsWith('mdal_')
    || eventType.startsWith('masc/mdal_')
    || eventType.startsWith('operator_')
    || eventType.startsWith('masc/operator_')
    || eventType.startsWith('command_plane_')
    || eventType.startsWith('masc/command_plane_')
  )
}

export function invalidateDashboardCache(): void {
  // Projection endpoints are intentionally fresh-first after the operator-console rewrite.
}

// --- Data fetchers ---

function normalizeAgentStatus(value: unknown): Agent['status'] {
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
  return 'offline'
}

function normalizeTaskStatus(value: unknown): Task['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'todo' || raw === 'in_progress' || raw === 'claimed' || raw === 'done' || raw === 'cancelled') {
    return raw
  }
  if (raw === 'inprogress') return 'in_progress'
  return 'todo'
}

function normalizeAgent(raw: unknown): Agent | null {
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

function normalizeTask(raw: unknown): Task | null {
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

function normalizeMessage(raw: unknown): Message | null {
  if (!isRecord(raw)) return null
  const from = asString(raw.from) ?? asString(raw.from_agent) ?? 'system'
  const content = asString(raw.content) ?? ''
  const timestamp = asString(raw.timestamp) ?? new Date().toISOString()
  return {
    id: asString(raw.id),
    seq: asNumber(raw.seq),
    from,
    content,
    timestamp,
    type: asString(raw.type),
  }
}

function normalizeExecutionTone(value: unknown): DashboardExecutionQueueItem['severity'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'ok' || raw === 'warn' || raw === 'bad') return raw
  return 'ok'
}

function normalizeExecutionSummary(raw: unknown): DashboardExecutionSummary | null {
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

function normalizeExecutionHandoff(raw: unknown): DashboardExecutionHandoff | null {
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

function normalizeExecutionQueueItem(raw: unknown): DashboardExecutionQueueItem | null {
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

function normalizeExecutionSessionBrief(raw: unknown): DashboardExecutionSessionBrief | null {
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
    required_count: asNumber(raw.required_count),
    top_handoff: normalizeExecutionHandoff(raw.top_handoff),
    intervene_handoff: normalizeExecutionHandoff(raw.intervene_handoff),
    command_handoff: normalizeExecutionHandoff(raw.command_handoff),
  }
}

function normalizeExecutionOperationBrief(raw: unknown): DashboardExecutionOperationBrief | null {
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

function normalizeExecutionWorkerSupportBrief(raw: unknown): DashboardExecutionWorkerSupportBrief | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name) ?? asString(raw.agent_name)
  const note = asString(raw.note)
  const focus = asString(raw.focus)
  const state = asString(raw.state)
  if (!name || !note || !focus || (state !== 'working' && state !== 'watching' && state !== 'quiet' && state !== 'offline')) {
    return null
  }
  return {
    name,
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    tone: normalizeExecutionTone(raw.tone),
    state,
    note,
    focus,
    last_signal_at: asString(raw.last_signal_at) ?? null,
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

function normalizeExecutionLodgeTick(raw: unknown): DashboardExecutionLodgeTick | null {
  if (!isRecord(raw)) return null
  const lastSystemSkipReason = asString(raw.last_system_skip_reason) ?? asString(raw.last_skip_reason) ?? null
  return {
    checked: asNumber(raw.checked),
    acted: asNumber(raw.acted),
    passed: asNumber(raw.passed),
    skipped: asNumber(raw.skipped),
    failed: asNumber(raw.failed),
    last_tick_at: asString(raw.last_tick_at) ?? null,
    last_skip_reason: lastSystemSkipReason,
    last_pass_reason: asString(raw.last_pass_reason) ?? null,
    last_system_skip_reason: lastSystemSkipReason,
    activity_report: asString(raw.activity_report) ?? null,
  }
}

function normalizeExecutionLodgeCheckin(raw: unknown): DashboardExecutionLodgeCheckin | null {
  if (!isRecord(raw)) return null
  const agentName = asString(raw.agent_name)
  const outcome = asString(raw.outcome)
  if (!agentName || !outcome) return null
  return {
    agent_name: agentName,
    trigger: asString(raw.trigger) ?? null,
    outcome,
    summary: asString(raw.summary) ?? null,
    reason: asString(raw.reason) ?? null,
    allowed_tool_names: asStringArray(raw.allowed_tool_names) ?? [],
    used_tool_names: asStringArray(raw.used_tool_names) ?? [],
    used_tool_call_count: asNumber(raw.used_tool_call_count) ?? null,
    action_kind: asString(raw.action_kind) ?? 'none',
    tool_audit_source: asString(raw.tool_audit_source) ?? null,
    tool_audit_at: asString(raw.tool_audit_at) ?? null,
    checked_at: asString(raw.checked_at) ?? null,
    decision_reason: asString(raw.decision_reason) ?? null,
    worker_name: asString(raw.worker_name) ?? null,
    failure_reason: asString(raw.failure_reason) ?? null,
  }
}

function normalizeExecutionContinuityBrief(raw: unknown): DashboardExecutionContinuityBrief | null {
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

function messageSortKey(message: Message): number {
  if (typeof message.seq === 'number' && Number.isFinite(message.seq)) return message.seq
  const parsed = Date.parse(message.timestamp)
  return Number.isNaN(parsed) ? 0 : parsed
}

function mergeMessages(current: Message[], incoming: Message[]): Message[] {
  if (incoming.length === 0) return current
  const byKey = new Map<string, Message>()
  for (const message of current) {
    const key = typeof message.seq === 'number'
      ? `seq:${message.seq}`
      : `ts:${message.timestamp}|from:${message.from}|content:${message.content}`
    byKey.set(key, message)
  }
  for (const message of incoming) {
    const key = typeof message.seq === 'number'
      ? `seq:${message.seq}`
      : `ts:${message.timestamp}|from:${message.from}|content:${message.content}`
    byKey.set(key, message)
  }
  return [...byKey.values()]
    .sort((a, b) => messageSortKey(a) - messageSortKey(b))
    .slice(-500)
}

function normalizeBuildIdentity(raw: unknown): ServerStatus['build'] | undefined {
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

function normalizeGardenerRuntimeStatus(raw: unknown): ServerStatus['gardener'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    enabled: raw.enabled === true,
    alive: raw.alive === true,
    status: asString(raw.status) ?? undefined,
    tick_in_progress: typeof raw.tick_in_progress === 'boolean' ? raw.tick_in_progress : undefined,
    tick_count: asNumber(raw.tick_count) ?? undefined,
    check_interval_sec: asNumber(raw.check_interval_sec) ?? undefined,
    last_tick_started_at: toIsoTimestamp(raw.last_tick_started_at) ?? asString(raw.last_tick_started_at) ?? null,
    last_tick_completed_at: toIsoTimestamp(raw.last_tick_completed_at) ?? asString(raw.last_tick_completed_at) ?? null,
    next_tick_due_at: toIsoTimestamp(raw.next_tick_due_at) ?? asString(raw.next_tick_due_at) ?? null,
    last_health_check_at: toIsoTimestamp(raw.last_health_check_at) ?? asString(raw.last_health_check_at) ?? null,
    last_intervention: asString(raw.last_intervention) ?? undefined,
    last_decision_source: asString(raw.last_decision_source) ?? undefined,
    last_action: asString(raw.last_action) ?? undefined,
    last_target: asString(raw.last_target) ?? null,
    last_reason: asString(raw.last_reason) ?? null,
    last_error: asString(raw.last_error) ?? null,
    circuit_open: typeof raw.circuit_open === 'boolean' ? raw.circuit_open : undefined,
    circuit_open_until: toIsoTimestamp(raw.circuit_open_until) ?? asString(raw.circuit_open_until) ?? null,
    can_spawn: typeof raw.can_spawn === 'boolean' ? raw.can_spawn : undefined,
    can_retire: typeof raw.can_retire === 'boolean' ? raw.can_retire : undefined,
    last_spawn_attempt_at: toIsoTimestamp(raw.last_spawn_attempt_at) ?? asString(raw.last_spawn_attempt_at) ?? null,
    last_retirement_attempt_at: toIsoTimestamp(raw.last_retirement_attempt_at) ?? asString(raw.last_retirement_attempt_at) ?? null,
    spawns_today: asNumber(raw.spawns_today) ?? undefined,
    retirements_today: asNumber(raw.retirements_today) ?? undefined,
    health_summary: isRecord(raw.health_summary)
      ? {
          total_agents: asNumber(raw.health_summary.total_agents) ?? undefined,
          active_agents: asNumber(raw.health_summary.active_agents) ?? undefined,
          idle_agents: asNumber(raw.health_summary.idle_agents) ?? undefined,
          todo_count: asNumber(raw.health_summary.todo_count) ?? undefined,
          high_priority_todo: asNumber(raw.health_summary.high_priority_todo) ?? undefined,
          orphan_count: asNumber(raw.health_summary.orphan_count) ?? undefined,
          homeostatic_score: asNumber(raw.health_summary.homeostatic_score) ?? undefined,
          needs_workers:
            typeof raw.health_summary.needs_workers === 'boolean'
              ? raw.health_summary.needs_workers
              : undefined,
        }
      : undefined,
  }
}

function normalizeGuardianRuntimeStatus(raw: unknown): ServerStatus['guardian'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    enabled: raw.enabled === true,
    mode: asString(raw.mode) ?? undefined,
    masc_enabled: typeof raw.masc_enabled === 'boolean' ? raw.masc_enabled : undefined,
    masc_loops_running: typeof raw.masc_loops_running === 'boolean' ? raw.masc_loops_running : undefined,
    runtime_owner: asString(raw.runtime_owner) ?? null,
    zombie_loop_running: typeof raw.zombie_loop_running === 'boolean' ? raw.zombie_loop_running : undefined,
    gc_loop_running: typeof raw.gc_loop_running === 'boolean' ? raw.gc_loop_running : undefined,
    lodge_enabled: typeof raw.lodge_enabled === 'boolean' ? raw.lodge_enabled : undefined,
    lodge_loop_started: typeof raw.lodge_loop_started === 'boolean' ? raw.lodge_loop_started : undefined,
    lodge_running: typeof raw.lodge_running === 'boolean' ? raw.lodge_running : undefined,
    last_zombie_cleanup: toIsoTimestamp(raw.last_zombie_cleanup) ?? asString(raw.last_zombie_cleanup) ?? null,
    last_gc: toIsoTimestamp(raw.last_gc) ?? asString(raw.last_gc) ?? null,
    last_lodge: toIsoTimestamp(raw.last_lodge) ?? asString(raw.last_lodge) ?? null,
    last_zombie_result: asString(raw.last_zombie_result) ?? null,
    last_gc_result: asString(raw.last_gc_result) ?? null,
    last_lodge_result: isRecord(raw.last_lodge_result)
      ? {
          ok: typeof raw.last_lodge_result.ok === 'boolean' ? raw.last_lodge_result.ok : undefined,
          message: asString(raw.last_lodge_result.message) ?? undefined,
        }
      : null,
  }
}

function normalizeSentinelRuntimeStatus(raw: unknown): ServerStatus['sentinel'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    enabled: raw.enabled === true,
    started: raw.started === true,
    agent_name: asString(raw.agent_name) ?? null,
    llm_enabled: typeof raw.llm_enabled === 'boolean' ? raw.llm_enabled : undefined,
    uptime_s: asNumber(raw.uptime_s) ?? undefined,
    embedded_guardian_loops_running:
      typeof raw.embedded_guardian_loops_running === 'boolean'
        ? raw.embedded_guardian_loops_running
        : undefined,
    guardian_runtime_owner: asString(raw.guardian_runtime_owner) ?? null,
    consumers: asStringArray(raw.consumers),
  }
}

function normalizeServerStatus(raw: unknown, generatedAt?: string): ServerStatus | null {
  if (!isRecord(raw)) return null
  return {
    ...(raw as ServerStatus),
    generated_at: generatedAt ?? toIsoTimestamp(raw.generated_at) ?? undefined,
    build: normalizeBuildIdentity(raw.build),
    lodge: normalizeLodgeRuntimeStatus(raw.lodge) ?? undefined,
    gardener: normalizeGardenerRuntimeStatus(raw.gardener) ?? undefined,
    guardian: normalizeGuardianRuntimeStatus(raw.guardian) ?? undefined,
    sentinel: normalizeSentinelRuntimeStatus(raw.sentinel) ?? undefined,
  }
}

function mergeServerStatus(previous: ServerStatus | null, next: ServerStatus | null): ServerStatus | null {
  if (!next) return previous
  if (!previous) return next
  return {
    ...previous,
    ...next,
    build: next.build ?? previous.build,
    generated_at: next.generated_at ?? previous.generated_at,
  }
}

function normalizeMdalStatus(value: unknown): MdalLoop['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'running' || raw === 'interrupted' || raw === 'completed' || raw === 'stopped' || raw === 'error') return raw
  if (raw.startsWith('error')) return 'error'
  return 'running'
}

function normalizeMdalIteration(raw: unknown): MdalIterationRecord | null {
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

function normalizeMdalLoop(raw: unknown): MdalLoop | null {
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
export async function refreshDashboard(): Promise<void> {
  dashboardLoading.value = true
  try {
    await Promise.all([refreshShell(), refreshExecution()])
    lastDashboardRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Dashboard refresh error:', err)
  } finally {
    dashboardLoading.value = false
  }
}

export async function refreshDashboardSemantics(): Promise<void> {
  dashboardSemanticsLoading.value = true
  dashboardSemanticsError.value = null
  try {
    const data = await fetchDashboardSemantics()
    dashboardSemantics.value = data
    lastDashboardSemanticsRefreshAt.value = new Date().toISOString()
  } catch (err) {
    dashboardSemanticsError.value =
      err instanceof Error ? err.message : 'Failed to load dashboard semantics'
  } finally {
    dashboardSemanticsLoading.value = false
  }
}

export function findDashboardSemanticSurface(
  surfaceId: DashboardSemanticSurfaceId | string,
): DashboardSemanticSurface | null {
  return dashboardSemantics.value?.surfaces.find(surface => surface.id === surfaceId) ?? null
}

export function findDashboardSemanticPanel(panelId: string): DashboardSemanticPanel | null {
  const surfaces = dashboardSemantics.value?.surfaces ?? []
  for (const surface of surfaces) {
    const panel = surface.panels.find(row => row.id === panelId)
    if (panel) return panel
  }
  return null
}

function applyPlanningEnvelope(data: {
  goals?: unknown[]
  mdal?: {
    loops?: unknown[]
    error?: string
  }
}): void {
  goals.value = (Array.isArray(data.goals) ? data.goals : [])
    .map((row): Goal | null => {
      if (!isRecord(row)) return null
      const id = asString(row.id)
      const title = asString(row.title)
      const horizon = asString(row.horizon)
      const status = asString(row.status)
      const createdAt = asString(row.created_at)
      const updatedAt = asString(row.updated_at)
      if (!id || !title || !horizon || !status || !createdAt || !updatedAt) return null
      return {
        id,
        horizon: horizon as Goal['horizon'],
        title,
        metric: asString(row.metric) ?? null,
        target_value: asString(row.target_value) ?? null,
        due_date: asString(row.due_date) ?? null,
        priority: asNumber(row.priority) ?? 3,
        status,
        parent_goal_id: asString(row.parent_goal_id) ?? null,
        last_review_note: asString(row.last_review_note) ?? null,
        last_review_at: asString(row.last_review_at) ?? null,
        created_at: createdAt,
        updated_at: updatedAt,
      }
    })
    .filter((row): row is Goal => row !== null)

  const nextLoops = new Map<string, MdalLoop>()
  const rows = Array.isArray(data.mdal?.loops) ? data.mdal.loops : []
  for (const row of rows) {
    const loop = normalizeMdalLoop(row)
    if (!loop) continue
    nextLoops.set(loop.loop_id, loop)
  }
  mdalLoops.value = nextLoops
  lastMdalError.value = typeof data.mdal?.error === 'string' ? data.mdal.error : null
  mdalSnapshotState.value =
    lastMdalError.value
      ? 'error'
      : nextLoops.size === 0
        ? 'idle'
        : 'ready'
}

export async function refreshShell(): Promise<void> {
  try {
    const data = await fetchDashboardShell()
    const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
    if (normalizedStatus) {
      serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
    }
  } catch (err) {
    console.error('Dashboard shell fetch error:', err)
  }
}

export async function refreshExecution(): Promise<void> {
  try {
    const data = await fetchDashboardExecution()
    const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
    const previousRoom = serverStatus.value?.room
    if (normalizedStatus) {
      serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
    }
    const roomChanged = previousRoom != null && normalizedStatus?.room != null && previousRoom !== normalizedStatus.room
    agents.value = (Array.isArray(data.agents) ? data.agents : [])
      .map(normalizeAgent)
      .filter((row): row is Agent => row !== null)
    tasks.value = (Array.isArray(data.tasks) ? data.tasks : [])
      .map(normalizeTask)
      .filter((row): row is Task => row !== null)
    const executionMessages = (Array.isArray(data.messages) ? data.messages : [])
      .map(normalizeMessage)
      .filter((row): row is Message => row !== null)
    messages.value = roomChanged ? executionMessages : mergeMessages(messages.value, executionMessages)
    keepers.value = normalizeKeepers(data.keepers)
    executionSummary.value = normalizeExecutionSummary(data.summary)
    executionLodgeTick.value = normalizeExecutionLodgeTick(data.lodge_tick)
    executionLodgeCheckins.value = (Array.isArray(data.lodge_checkins) ? data.lodge_checkins : [])
      .map(normalizeExecutionLodgeCheckin)
      .filter((row): row is DashboardExecutionLodgeCheckin => row !== null)
    executionQueue.value = (Array.isArray(data.execution_queue) ? data.execution_queue : Array.isArray(data.priority_queue) ? data.priority_queue : [])
      .map(normalizeExecutionQueueItem)
      .filter((row): row is DashboardExecutionQueueItem => row !== null)
    executionSessionBriefs.value = (Array.isArray(data.session_briefs) ? data.session_briefs : [])
      .map(normalizeExecutionSessionBrief)
      .filter((row): row is DashboardExecutionSessionBrief => row !== null)
    executionOperationBriefs.value = (Array.isArray(data.operation_briefs) ? data.operation_briefs : [])
      .map(normalizeExecutionOperationBrief)
      .filter((row): row is DashboardExecutionOperationBrief => row !== null)
    executionWorkerSupportBriefs.value = (Array.isArray(data.worker_support_briefs) ? data.worker_support_briefs : Array.isArray(data.worker_briefs) ? data.worker_briefs : [])
      .map(normalizeExecutionWorkerSupportBrief)
      .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
    executionContinuityBriefs.value = (Array.isArray(data.continuity_briefs) ? data.continuity_briefs : [])
      .map(normalizeExecutionContinuityBrief)
      .filter((row): row is DashboardExecutionContinuityBrief => row !== null)
    executionOfflineWorkerBriefs.value = (Array.isArray(data.offline_worker_briefs) ? data.offline_worker_briefs : [])
      .map(normalizeExecutionWorkerSupportBrief)
      .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
    perpetualStatus.value = null
    lastDashboardRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Dashboard execution fetch error:', err)
  }
}

export async function refreshAgents(): Promise<void> {
  return refreshExecution()
}

export async function refreshTasks(): Promise<void> {
  return refreshExecution()
}

export async function refreshMessages(): Promise<void> {
  try {
    const current = messages.value
    const maxSeq = current.reduce((max, message) => Math.max(max, message.seq ?? 0), 0)
    const data = await fetchMessagesList(maxSeq)
    const incoming = (Array.isArray(data.messages) ? data.messages : [])
      .map(normalizeMessage)
      .filter((row): row is Message => row !== null)
    messages.value = mergeMessages(current, incoming)
  } catch (err) {
    console.error('Messages selective fetch error:', err)
  }
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const data = await fetchDashboardMemory(boardSortMode.value, { excludeSystem: boardExcludeSystem.value })
    boardPosts.value = data.posts ?? []
    lastBoardRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Board fetch error:', err)
  } finally {
    boardLoading.value = false
  }
}

export async function refreshTrpg(): Promise<void> {
  trpgLoading.value = true
  try {
    const room = trpgRoom.value || serverStatus.value?.room || 'default'
    if (!trpgRoom.value) trpgRoom.value = room
    const data = await fetchTrpgState(room)
    trpgState.value = data
  } catch (err) {
    console.error('TRPG fetch error:', err)
  } finally {
    trpgLoading.value = false
  }
}

// --- Goals fetcher ---

export async function refreshGoals(): Promise<void> {
  goalsLoading.value = true
  mdalLoading.value = true
  try {
    const data = await fetchDashboardPlanning()
    applyPlanningEnvelope(data)
    lastGoalsRefreshAt.value = new Date().toISOString()
    lastMdalRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Planning fetch error:', err)
    mdalSnapshotState.value = 'error'
    lastMdalError.value = err instanceof Error ? err.message : String(err)
  } finally {
    goalsLoading.value = false
    mdalLoading.value = false
  }
}

export async function refreshMdal(): Promise<void> {
  return refreshGoals()
}
