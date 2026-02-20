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
  BoardPost,
  ServerStatus,
  PerpetualStatus,
  TrpgState,
  BoardSortMode,
  KeeperLifecycleState,
} from './types'
import { fetchDashboard, fetchBoard, fetchTrpgState } from './api'
import { lastEvent } from './sse'

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

// --- TRPG state ---

export const trpgState = signal<TrpgState | null>(null)
export const trpgRoom = signal<string>('')

// --- Loading flags ---

export const dashboardLoading = signal(false)
export const boardLoading = signal(false)
export const trpgLoading = signal(false)

// --- Derived state ---

export const activeAgents: ReadonlySignal<Agent[]> = computed(() =>
  agents.value.filter(a => a.status === 'active' || a.status === 'idle')
)

export const tasksByStatus = computed(() => {
  const all = tasks.value
  return {
    todo: all.filter(t => t.status === 'todo'),
    inProgress: all.filter(t => t.status === 'in_progress' || t.status === 'claimed'),
    done: all.filter(t => t.status === 'done'),
  }
})

// --- Keeper lifecycle derivation ---

export function deriveLifecycleState(keeper: Keeper): KeeperLifecycleState {
  const series = keeper.metrics_series
  if (!series || series.length === 0) {
    const status = keeper.status?.toLowerCase() ?? ''
    if (status === 'offline' || status === 'inactive') return 'offline'
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

export const staleKeepers: ReadonlySignal<Set<string>> = computed(() => {
  const now = Date.now()
  const stale = new Set<string>()
  const hb = keeperHeartbeats.value
  for (const k of keepers.value) {
    const lastTs = hb.get(k.name)
    if (lastTs != null && (now - lastTs) > HEARTBEAT_STALE_MS) {
      stale.add(k.name)
    }
  }
  return stale
})

// --- Cache for dashboard batch ---

let _dashboardCache: { data: unknown; time: number } | null = null
const DASHBOARD_CACHE_TTL = 5000

export function invalidateDashboardCache(): void {
  _dashboardCache = null
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

function normalizeAgentStatus(value: unknown): Agent['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (raw === 'active' || raw === 'idle' || raw === 'inactive' || raw === 'offline') return raw
  if (raw === 'busy' || raw === 'in_progress' || raw === 'claimed') return 'active'
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

function normalizeKeepers(raw: unknown): Keeper[] {
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
              status: asString(agentRaw.status),
              current_task: asString(agentRaw.current_task) ?? null,
              last_seen: asString(agentRaw.last_seen),
            }
          : undefined

      const metricsSeries = normalizeMetricsSeries(row.metrics_series)

      return {
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
        last_heartbeat: asString(row.last_heartbeat) ?? asString(agentRaw?.last_seen),
        generation: asNumber(row.generation),
        turn_count: asNumber(row.turn_count) ?? asNumber(row.total_turns),
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
        skill_primary: asString(row.skill_primary) ?? null,
        skill_secondary: skillSecondary,
        skill_reason: asString(row.skill_reason) ?? null,
        metrics_series: metricsSeries.length > 0 ? metricsSeries : undefined,
        metrics_window: metricsWindowRaw as Keeper['metrics_window'],
        agent: normalizedAgent,
      }
    })
    .filter((row): row is Keeper => row !== null)
}

export async function refreshDashboard(): Promise<void> {
  const now = Date.now()
  if (_dashboardCache && (now - _dashboardCache.time) < DASHBOARD_CACHE_TTL) {
    return // Use cached data (already applied to signals)
  }

  dashboardLoading.value = true
  try {
    const data = await fetchDashboard()
    _dashboardCache = { data, time: now }

    agents.value = (Array.isArray(data.agents?.agents) ? data.agents.agents : [])
      .map(normalizeAgent)
      .filter((row): row is Agent => row !== null)
    tasks.value = (Array.isArray(data.tasks?.tasks) ? data.tasks.tasks : [])
      .map(normalizeTask)
      .filter((row): row is Task => row !== null)
    messages.value = (Array.isArray(data.messages?.messages) ? data.messages.messages : [])
      .map(normalizeMessage)
      .filter((row): row is Message => row !== null)
    keepers.value = normalizeKeepers(data.keepers)
    serverStatus.value = isRecord(data.status) ? (data.status as ServerStatus) : null
    perpetualStatus.value = data.perpetual ?? null
  } catch (err) {
    console.error('Dashboard fetch error:', err)
  } finally {
    dashboardLoading.value = false
  }
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const data = await fetchBoard()
    boardPosts.value = data.posts ?? []
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

// --- SSE event reaction ---
// When lastEvent changes, invalidate cache and re-fetch

let _fetchDebounce: ReturnType<typeof setTimeout> | null = null
let _boardDebounce: ReturnType<typeof setTimeout> | null = null

export function setupSSEReaction(): () => void {
  // Subscribe to SSE events and trigger refreshes
  const unsubscribe = lastEvent.subscribe((event) => {
    if (!event) return

    // Handle keeper heartbeat events — update heartbeat map without full refresh
    if (event.type === 'keeper_heartbeat' && event.name) {
      const next = new Map(keeperHeartbeats.value)
      next.set(event.name, event.ts_unix ? event.ts_unix * 1000 : Date.now())
      keeperHeartbeats.value = next
    }

    invalidateDashboardCache()

    // Debounced dashboard refresh
    if (!_fetchDebounce) {
      _fetchDebounce = setTimeout(() => {
        refreshDashboard()
        _fetchDebounce = null
      }, 500)
    }

    // Board-specific events trigger board refresh
    if (event.type === 'board_post' || event.type === 'board_comment') {
      if (!_boardDebounce) {
        _boardDebounce = setTimeout(() => {
          refreshBoard()
          _boardDebounce = null
        }, 500)
      }
    }

    // Keeper events trigger dashboard refresh for up-to-date metrics
    if (event.type === 'keeper_handoff' || event.type === 'keeper_compaction' || event.type === 'keeper_guardrail') {
      invalidateDashboardCache()
    }
  })

  return unsubscribe
}

// --- Periodic refresh (for keeper presence heartbeats that don't emit SSE) ---

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    invalidateDashboardCache()
    refreshDashboard()
  }, 10000)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}
