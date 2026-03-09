// MASC Dashboard — Centralized reactive state via @preact/signals
// SSE events and API responses update these signals;
// subscribing components re-render automatically.

import { signal, computed, type ReadonlySignal } from '@preact/signals'
import type {
  Agent,
  Task,
  Message,
  Keeper,
  KeeperMetricPoint,
  KeeperDiagnostic,
  BoardPost,
  ServerStatus,
  PerpetualStatus,
  TrpgState,
  BoardSortMode,
  KeeperLifecycleState,
  Goal,
  MdalLoop,
  MdalIterationRecord,
} from './types'
import {
  fetchDashboard, fetchBoard, fetchTrpgState, fetchGoals, fetchMdalLoops,
  fetchAgentsList, fetchTasksList, fetchMessagesList,
  type DashboardMode,
} from './api'
import { lastEvent, connected, journal } from './sse'
import { deriveKeeperDiagnostic, normalizeLodgeRuntimeStatus } from './keeper-runtime'
import { buildAgentMotion, type AgentMotionSnapshot } from './components/common/agent-motion'

// --- Core state signals ---

export const agents = signal<Agent[]>([])
export const tasks = signal<Task[]>([])
export const messages = signal<Message[]>([])
export const keepers = signal<Keeper[]>([])
export const serverStatus = signal<ServerStatus | null>(null)
export const perpetualStatus = signal<PerpetualStatus | null>(null)

// --- Keeper heartbeat tracking (name -> last heartbeat timestamp ms) ---

export const keeperHeartbeats = signal<Map<string, number>>(new Map())

// --- Board state ---

export const boardPosts = signal<BoardPost[]>([])
export const boardSortMode = signal<BoardSortMode>('hot')
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

// --- Refresh timestamps ---

export const lastDashboardRefreshAt = signal<string | null>(null)
export const lastBoardRefreshAt = signal<string | null>(null)
export const lastGoalsRefreshAt = signal<string | null>(null)
export const lastMdalRefreshAt = signal<string | null>(null)

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

// --- Keeper lifecycle derivation ---

export function deriveLifecycleState(keeper: Keeper): KeeperLifecycleState {
  const status = keeper.status?.toLowerCase() ?? ''
  if (status === 'offline' || status === 'inactive') return 'offline'

  const series = keeper.metrics_series
  if (!series || series.length === 0) {
    return 'idle'
  }
  const latest = series[series.length - 1]
  if (!latest) return 'idle'
  if (latest.is_handoff) return 'handoff-imminent'
  if (latest.is_compaction) return 'compacting'
  const ratio = latest.context_ratio
  if (ratio > 0.85) return 'handoff-imminent'
  if (ratio > 0.70) return 'preparing'
  if (ratio > 0.50) return 'compacting'
  return 'active'
}

export const keeperLifecycles: ReadonlySignal<Map<string, KeeperLifecycleState>> = computed(() => {
  const map = new Map<string, KeeperLifecycleState>()
  for (const k of keepers.value) {
    map.set(k.name, deriveLifecycleState(k))
  }
  return map
})

// Heartbeat staleness threshold (120 seconds)
const HEARTBEAT_STALE_MS = 120_000

function keeperFreshnessTs(keeper: Keeper, heartbeats: Map<string, number>): number | null {
  const mapped = heartbeats.get(keeper.name)
  if (mapped != null) return mapped

  const direct = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : Number.NaN
  if (!Number.isNaN(direct)) return direct

  const ageSeconds = [
    keeper.last_turn_ago_s,
    keeper.last_proactive_ago_s,
    keeper.last_handoff_ago_s,
    keeper.last_compaction_ago_s,
  ].find(value => typeof value === 'number' && Number.isFinite(value) && value >= 0)

  return typeof ageSeconds === 'number'
    ? Date.now() - (ageSeconds * 1000)
    : null
}

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

// --- Cache for dashboard batch ---

const _dashboardCache: Partial<Record<DashboardMode, { data: unknown; time: number }>> = {}
const DASHBOARD_CACHE_TTL = 5000
let _fetchDebounce: ReturnType<typeof setTimeout> | null = null

function isDashboardRefreshEvent(eventType: string): boolean {
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
  delete _dashboardCache.compact
  delete _dashboardCache.full
}

// --- Data fetchers ---

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined
  const rows = value.filter((v): v is string => typeof v === 'string' && v.trim() !== '')
  return rows.length > 0 ? rows : undefined
}

function toIsoTimestamp(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim() !== '') return value
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return undefined
  return new Date(value * 1000).toISOString()
}

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
    status: normalizeAgentStatus(raw.status),
    current_task: asString(raw.current_task) ?? null,
    last_seen: asString(raw.last_seen),
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

function normalizeMetricsSeries(raw: unknown): KeeperMetricPoint[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((item): KeeperMetricPoint | null => {
      if (!isRecord(item)) return null
      const ts = asNumber(item.ts_unix)
      if (ts == null) return null
      const handoffObj = isRecord(item.handoff) ? item.handoff : null
      return {
        ts,
        context_ratio: asNumber(item.context_ratio) ?? 0,
        context_tokens: asNumber(item.context_tokens) ?? 0,
        context_max: asNumber(item.context_max) ?? 0,
        latency_ms: asNumber(item.latency_ms) ?? 0,
        generation: asNumber(item.generation) ?? 0,
        channel: typeof item.channel === 'string' ? item.channel : 'turn',
        is_handoff: handoffObj != null && item.handoff_performed === true,
        is_compaction: item.compacted === true,
        compaction_saved_tokens: asNumber(item.compaction_saved_tokens) ?? 0,
        compaction_trigger: typeof item.compaction_trigger === 'string' ? item.compaction_trigger : null,
        model_used: typeof item.model_used === 'string' ? item.model_used : '',
        cost_usd: asNumber(item.cost_usd) ?? 0,
        handoff_to_model: handoffObj ? (typeof handoffObj.to_model === 'string' ? handoffObj.to_model : null) : null,
        handoff_new_generation: handoffObj ? (asNumber(handoffObj.new_generation) ?? null) : null,
      }
    })
    .filter((item): item is KeeperMetricPoint => item !== null)
}

function normalizeKeeperDiagnostic(raw: unknown): KeeperDiagnostic | null {
  if (!isRecord(raw)) return null
  const healthState = asString(raw.health_state)
  const nextActionPath = asString(raw.next_action_path)
  const lastReplyStatus = asString(raw.last_reply_status)
  if (!healthState || !nextActionPath || !lastReplyStatus) return null
  const quietReason = (asString(raw.quiet_reason) ?? null) as KeeperDiagnostic['quiet_reason']
  const summary =
    asString(raw.summary)
    ?? (
      healthState === 'offline' || healthState === 'degraded' || healthState === 'stale'
        ? 'Keeper is not in a healthy reply state. Probe or recover before relying on automation.'
        : quietReason === 'quiet_hours'
          ? 'Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.'
          : quietReason === 'min_gap'
            ? 'Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.'
            : quietReason === 'never_started'
              ? 'Keeper metadata exists but no reply turn has been recorded yet.'
              : 'Keeper is reachable. Send a direct message for an immediate response.'
    )
  return {
    health_state: healthState as KeeperDiagnostic['health_state'],
    quiet_reason: quietReason,
    next_action_path: nextActionPath as KeeperDiagnostic['next_action_path'],
    last_reply_status: lastReplyStatus as KeeperDiagnostic['last_reply_status'],
    last_reply_at: toIsoTimestamp(raw.last_reply_at) ?? asString(raw.last_reply_at) ?? null,
    last_reply_preview: asString(raw.last_reply_preview) ?? null,
    last_error: asString(raw.last_error) ?? null,
    next_eligible_at_s: asNumber(raw.next_eligible_at_s) ?? null,
    recoverable:
      typeof raw.recoverable === 'boolean'
        ? raw.recoverable
        : nextActionPath === 'recover',
    summary,
    keepalive_running:
      typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
  }
}

function normalizeKeepers(raw: unknown, serverStatusValue?: ServerStatus | null): Keeper[] {
  const rows =
    Array.isArray(raw)
      ? raw
      : isRecord(raw) && Array.isArray(raw.keepers)
        ? raw.keepers
        : []

  return rows
    .map((row): Keeper | null => {
      if (!isRecord(row)) return null
      const agentRaw = isRecord(row.agent) ? row.agent : null
      const contextRaw = isRecord(row.context) ? row.context : null
      const metricsWindowRaw = isRecord(row.metrics_window) ? row.metrics_window : undefined

      const name = asString(row.name)
      if (!name) return null

      const contextRatio = asNumber(row.context_ratio) ?? asNumber(contextRaw?.context_ratio)
      const statusRaw = asString(row.status) ?? asString(agentRaw?.status) ?? 'offline'
      const status = normalizeAgentStatus(statusRaw)
      const model = asString(row.model) ?? asString(row.active_model) ?? asString(row.primary_model)
      const skillSecondary = asStringArray(row.skill_secondary)

      const normalizedContext =
        contextRaw
          ? {
              source: asString(contextRaw.source),
              context_ratio: asNumber(contextRaw.context_ratio),
              context_tokens: asNumber(contextRaw.context_tokens),
              context_max: asNumber(contextRaw.context_max),
              message_count: asNumber(contextRaw.message_count),
              has_checkpoint: typeof contextRaw.has_checkpoint === 'boolean' ? contextRaw.has_checkpoint : undefined,
            }
          : undefined

      const normalizedAgent =
        agentRaw
          ? {
              name: asString(agentRaw.name),
              exists: typeof agentRaw.exists === 'boolean' ? agentRaw.exists : undefined,
              error: asString(agentRaw.error),
              status: asString(agentRaw.status),
              current_task: asString(agentRaw.current_task) ?? null,
              last_seen: asString(agentRaw.last_seen),
              last_seen_ago_s: asNumber(agentRaw.last_seen_ago_s),
              is_zombie: typeof agentRaw.is_zombie === 'boolean' ? agentRaw.is_zombie : undefined,
            }
          : undefined

      const metricsSeries = normalizeMetricsSeries(row.metrics_series)

      const keeper: Keeper = {
        name,
        emoji: asString(row.emoji),
        koreanName: asString(row.koreanName) ?? asString(row.korean_name),
        agent_name: asString(row.agent_name),
        trace_id: asString(row.trace_id),
        model,
        primary_model: asString(row.primary_model),
        active_model: asString(row.active_model),
        next_model_hint: asString(row.next_model_hint) ?? null,
        status,
        presence_keepalive:
          typeof row.presence_keepalive === 'boolean' ? row.presence_keepalive : undefined,
        presence_keepalive_sec: asNumber(row.presence_keepalive_sec),
        keepalive_running:
          typeof row.keepalive_running === 'boolean' ? row.keepalive_running : undefined,
        proactive_enabled:
          typeof row.proactive_enabled === 'boolean' ? row.proactive_enabled : undefined,
        reactive_enabled:
          typeof row.reactive_enabled === 'boolean' ? row.reactive_enabled : undefined,
        proactive_idle_sec: asNumber(row.proactive_idle_sec),
        proactive_cooldown_sec: asNumber(row.proactive_cooldown_sec),
        last_heartbeat: asString(row.last_heartbeat) ?? asString(agentRaw?.last_seen),
        generation: asNumber(row.generation),
        turn_count: asNumber(row.turn_count) ?? asNumber(row.total_turns),
        keeper_age_s: asNumber(row.keeper_age_s),
        last_turn_ago_s: asNumber(row.last_turn_ago_s),
        last_handoff_ago_s: asNumber(row.last_handoff_ago_s),
        last_compaction_ago_s: asNumber(row.last_compaction_ago_s),
        last_proactive_ago_s: asNumber(row.last_proactive_ago_s),
        last_successful_reaction_at:
          toIsoTimestamp(row.last_successful_reaction_at)
          ?? asString(row.last_successful_reaction_at)
          ?? null,
        last_successful_reaction_summary:
          asString(row.last_successful_reaction_summary) ?? null,
        last_handled_event_id: asString(row.last_handled_event_id) ?? null,
        last_handled_event_ts:
          toIsoTimestamp(row.last_handled_event_ts)
          ?? asString(row.last_handled_event_ts)
          ?? null,
        pending_reactive_items: asNumber(row.pending_reactive_items),
        inbox_latest_summary: asString(row.inbox_latest_summary) ?? null,
        continuity_summary: asString(row.continuity_summary) ?? null,
        timeout_streak: asNumber(row.timeout_streak),
        recent_provider_failures: asNumber(row.recent_provider_failures),
        recent_fallback_rate: asNumber(row.recent_fallback_rate),
        context_ratio: contextRatio,
        context_tokens: asNumber(row.context_tokens) ?? asNumber(contextRaw?.context_tokens),
        context_max: asNumber(row.context_max) ?? asNumber(contextRaw?.context_max),
        context_source: asString(row.context_source) ?? asString(contextRaw?.source),
        context: normalizedContext,
        traits: asStringArray(row.traits),
        interests: asStringArray(row.interests),
        primaryValue: asString(row.primaryValue) ?? asString(row.primary_value),
        activityLevel: asNumber(row.activityLevel) ?? asNumber(row.activity_level),
        memory_recent_note: asString(row.memory_recent_note) ?? null,
        conversation_tail_count: asNumber(row.conversation_tail_count),
        k2k_count: asNumber(row.k2k_count),
        handoff_count_total: asNumber(row.handoff_count_total) ?? asNumber(row.trace_history_count),
        compaction_count: asNumber(row.compaction_count),
        last_compaction_saved_tokens: asNumber(row.last_compaction_saved_tokens),
        diagnostic: normalizeKeeperDiagnostic(row.diagnostic),
        skill_primary: asString(row.skill_primary) ?? null,
        skill_secondary: skillSecondary,
        skill_reason: asString(row.skill_reason) ?? null,
        metrics_series: metricsSeries.length > 0 ? metricsSeries : undefined,
        metrics_window: metricsWindowRaw as Keeper['metrics_window'],
        agent: normalizedAgent,
      }
      keeper.diagnostic =
        normalizeKeeperDiagnostic(row.diagnostic)
        ?? deriveKeeperDiagnostic(keeper, serverStatusValue?.lodge ?? null)
      return keeper
    })
    .filter((row): row is Keeper => row !== null)
}

function normalizeServerStatus(raw: unknown): ServerStatus | null {
  if (!isRecord(raw)) return null
  return {
    ...(raw as ServerStatus),
    lodge: normalizeLodgeRuntimeStatus(raw.lodge) ?? undefined,
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
export async function refreshDashboard(mode: DashboardMode = 'full'): Promise<void> {
  const now = Date.now()
  const cached = _dashboardCache[mode]
  if (cached && (now - cached.time) < DASHBOARD_CACHE_TTL) {
    return // Use cached data (already applied to signals)
  }

  dashboardLoading.value = true
  try {
    const data = await fetchDashboard(mode)
    _dashboardCache[mode] = { data, time: now }

    agents.value = (Array.isArray(data.agents?.agents) ? data.agents.agents : [])
      .map(normalizeAgent)
      .filter((row): row is Agent => row !== null)
    tasks.value = (Array.isArray(data.tasks?.tasks) ? data.tasks.tasks : [])
      .map(normalizeTask)
      .filter((row): row is Task => row !== null)
    messages.value = (Array.isArray(data.messages?.messages) ? data.messages.messages : [])
      .map(normalizeMessage)
      .filter((row): row is Message => row !== null)
    const normalizedStatus = normalizeServerStatus(data.status)
    serverStatus.value = normalizedStatus
    keepers.value = normalizeKeepers(data.keepers, normalizedStatus)
    perpetualStatus.value = data.perpetual ?? null
    lastDashboardRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Dashboard fetch error:', err)
  } finally {
    dashboardLoading.value = false
  }
}

// --- Selective refresh: individual resource fetchers with merge ---
// Individual endpoints return simplified fields. Merge preserves rich data
// from the initial full dashboard load (emoji, koreanName, model, etc.).

export async function refreshAgents(): Promise<void> {
  try {
    const data = await fetchAgentsList()
    const incoming = (Array.isArray(data.agents) ? data.agents : [])
      .map(normalizeAgent)
      .filter((a): a is Agent => a !== null)
    const prev = agents.value
    const prevMap = new Map(prev.map(a => [a.name, a]))
    agents.value = incoming.map(a => {
      const old = prevMap.get(a.name)
      if (!old) return a
      return { ...old, status: a.status, current_task: a.current_task }
    })
  } catch (err) {
    console.error('Agents selective fetch error:', err)
  }
}

export async function refreshTasks(): Promise<void> {
  try {
    const data = await fetchTasksList({ includeDone: true, includeCancelled: true })
    const incoming = (Array.isArray(data.tasks) ? data.tasks : [])
      .map(normalizeTask)
      .filter((t): t is Task => t !== null)
    const prev = tasks.value
    const prevMap = new Map(prev.map(t => [t.id, t]))
    tasks.value = incoming.map(t => {
      const old = prevMap.get(t.id)
      if (!old) return t
      return {
        ...old,
        status: t.status,
        priority: t.priority ?? old.priority,
        assignee: t.assignee ?? old.assignee,
      }
    })
  } catch (err) {
    console.error('Tasks selective fetch error:', err)
  }
}

export async function refreshMessages(): Promise<void> {
  try {
    const current = messages.value
    const maxSeq = current.reduce((m, msg) => Math.max(m, msg.seq ?? 0), 0)
    const data = await fetchMessagesList(maxSeq)
    const incoming = (Array.isArray(data.messages) ? data.messages : [])
      .map(normalizeMessage)
      .filter((m): m is Message => m !== null)
    if (incoming.length === 0) return
    const existingSeqs = new Set(
      current.map(m => m.seq).filter((s): s is number => s != null),
    )
    const existingKeys = new Set(
      current.filter(m => m.seq == null).map(m => `${m.timestamp}|${m.from}`),
    )
    const fresh = incoming.filter(m => {
      if (m.seq != null) return !existingSeqs.has(m.seq)
      const key = `${m.timestamp}|${m.from}`
      if (existingKeys.has(key)) return false
      existingKeys.add(key)
      return true
    })
    if (fresh.length > 0) {
      const merged = [...current, ...fresh]
      // Cap at 500 messages to prevent unbounded growth in long sessions
      messages.value = merged.length > 500 ? merged.slice(-500) : merged
    }
  } catch (err) {
    console.error('Messages selective fetch error:', err)
  }
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const data = await fetchBoard(boardSortMode.value, { excludeSystem: boardExcludeSystem.value })
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
  try {
    const data = await fetchGoals()
    goals.value = Array.isArray(data) ? data : []
    lastGoalsRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.error('Goals fetch error:', err)
  } finally {
    goalsLoading.value = false
  }
}

export async function refreshMdal(): Promise<void> {
  mdalLoading.value = true
  try {
    const data = await fetchMdalLoops()
    const rows = Array.isArray(data.loops) ? data.loops : []
    const next = new Map<string, MdalLoop>()
    for (const row of rows) {
      const loop = normalizeMdalLoop(row)
      if (!loop) continue
      next.set(loop.loop_id, loop)
    }
    mdalLoops.value = next
    lastMdalRefreshAt.value = new Date().toISOString()
    lastMdalError.value = null
    mdalSnapshotState.value = next.size === 0 ? 'idle' : 'ready'
  } catch (err) {
    console.error('MDAL fetch error:', err)
    mdalSnapshotState.value = 'error'
    lastMdalError.value = err instanceof Error ? err.message : String(err)
  } finally {
    mdalLoading.value = false
  }
}

// --- Council refresh registration (avoids circular import) ---
let _refreshCouncilFn: (() => void) | null = null
export function registerCouncilRefresh(fn: () => void): void {
  _refreshCouncilFn = fn
}

let _refreshCommandPlaneFn: (() => void) | null = null
export function registerCommandPlaneRefresh(fn: () => void): void {
  _refreshCommandPlaneFn = fn
}
// --- SSE event reaction ---
// When lastEvent changes, route to the minimal refresh needed.

const _debounceTimers: Record<string, ReturnType<typeof setTimeout>> = {}

/** Schedule a debounced refresh for the given key. Coalesces rapid events. */
function scheduleRefresh(key: string, fn: () => void, delayMs = 500): void {
  if (_debounceTimers[key]) clearTimeout(_debounceTimers[key])
  _debounceTimers[key] = setTimeout(() => {
    fn()
    delete _debounceTimers[key]
  }, delayMs)
}

export function setupSSEReaction(): () => void {
  // Subscribe to SSE events and trigger per-resource refreshes
  const unsubscribe = lastEvent.subscribe((event) => {
    if (!event) return

    // Keeper heartbeat — update signal directly, zero network calls
    if (event.type === 'keeper_heartbeat' && event.name) {
      const next = new Map(keeperHeartbeats.value)
      next.set(event.name, event.ts_unix ? event.ts_unix * 1000 : Date.now())
      keeperHeartbeats.value = next
      return
    }

    // Agent events → fetch agents only
    if (event.type === 'agent_joined' || event.type === 'agent_left') {
      scheduleRefresh('agents', refreshAgents)
    }

    // Dashboard data events — debounced full refresh
    if (isDashboardRefreshEvent(event.type)) {
      invalidateDashboardCache()
      if (!_fetchDebounce) {
        _fetchDebounce = setTimeout(() => {
          refreshDashboard()
          _refreshCommandPlaneFn?.()
          _fetchDebounce = null
        }, 500)
      }
    }

    // Task events → fetch tasks only
    if (event.type.startsWith('task_') || event.type.startsWith('masc/task_')) {
      scheduleRefresh('tasks', refreshTasks)
    }

    // Broadcast → fetch new messages only (append-only via since_seq)
    if (event.type === 'broadcast') {
      scheduleRefresh('messages', refreshMessages)
    }

    // Keeper lifecycle events → full dashboard (keeper data only in bundle)
    if (
      event.type === 'keeper_handoff'
      || event.type === 'keeper_compaction'
      || event.type === 'keeper_guardrail'
    ) {
      scheduleRefresh('dashboard', () => {
        invalidateDashboardCache()
        refreshDashboard()
      })
    }

    // Board events → board refresh only
    if (
      event.type === 'board_post'
      || event.type === 'masc/board_post'
      || event.type === 'board_comment'
      || event.type === 'masc/board_comment'
    ) {
      scheduleRefresh('board', refreshBoard)
    }

    // Council events
    if (event.type.startsWith('decision_')) {
      scheduleRefresh('council', () => _refreshCouncilFn?.())
    }

    // MDAL events
    if (
      event.type === 'mdal_started'
      || event.type === 'mdal_iteration'
      || event.type === 'mdal_completed'
      || event.type === 'mdal_stopped'
    ) {
      scheduleRefresh('mdal', refreshMdal, 350)
    }
  })

  return () => {
    unsubscribe()
    for (const key of Object.keys(_debounceTimers)) {
      clearTimeout(_debounceTimers[key])
      delete _debounceTimers[key]
    }
  }
}

// --- Periodic refresh (for keeper presence heartbeats that don't emit SSE) ---

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    if (!connected.value) {
      invalidateDashboardCache()
    }
    refreshDashboard()
  }, 10000)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}
