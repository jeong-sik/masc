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
  DashboardSemanticPanel,
  DashboardExecutionHandoff,
  DashboardExecutionSummary,
  DashboardExecutionQueueItem,
  DashboardExecutionSessionBrief,
  DashboardExecutionOperationBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionLodgeTick,
  DashboardExecutionLodgeCheckin,
  SocialRuntimeStatus,
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
  fetchAgentActivity,
  type AgentActivityEntry,
} from './api'
import { journal } from './sse'
import {
  deriveLifecycleState,
  keeperFreshnessTs,
  normalizeKeepers,
} from './keeper-store-normalize'
import { buildAgentMotion, type AgentMotionSnapshot } from './components/common/agent-motion'
import { isRecord, asString, asNumber } from './components/common/normalize'
import {
  normalizeAgent, normalizeTask, normalizeMessage,
  normalizeExecutionSummary, normalizeExecutionHandoff,
  normalizeExecutionQueueItem, normalizeExecutionSessionBrief,
  normalizeExecutionOperationBrief, normalizeExecutionWorkerSupportBrief,
  normalizeExecutionLodgeTick, normalizeExecutionLodgeCheckin,
  normalizeExecutionContinuityBrief,
  messageSortKey, mergeMessages,
  normalizeServerStatus, mergeServerStatus,
  normalizeMdalLoop, normalizeBuildIdentity,
} from './store-normalizers'

// --- Shell counts (lightweight fallback from /dashboard/shell) ---

export interface ShellCounts {
  agents: number
  tasks: number
  keepers: number
}

export const shellCounts = signal<ShellCounts | null>(null)
export const agentActivity = signal<AgentActivityEntry[]>([])

// --- Provider capacity ---

export interface GlmModelStats {
  model: string
  in_flight: number
  limit: number
}

export interface ProviderCapacity {
  glm_pool: {
    models: GlmModelStats[]
    total_capacity: number
    current_load: number
    has_capacity: boolean
  }
  agent_capacity: {
    gardener_enabled: boolean
    min_agents: number
    target_agents: number
    max_agents: number
  }
}

export const providerCapacity = signal<ProviderCapacity | null>(null)

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
    // Extract lightweight counts for fast initial render (before execution loads)
    if (data.counts) {
      shellCounts.value = {
        agents: data.counts.agents ?? 0,
        tasks: data.counts.tasks ?? 0,
        keepers: data.counts.keepers ?? 0,
      }
    }
    if (data.providers) {
      providerCapacity.value = data.providers as unknown as ProviderCapacity
    }
  } catch (err) {
    console.error('Dashboard shell fetch error:', err)
  }
}

export async function refreshAgentActivity(): Promise<void> {
  try {
    const data = await fetchAgentActivity(24)
    agentActivity.value = data.agents ?? []
  } catch (err) {
    console.error('Agent activity fetch error:', err)
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
    const socialCheckinsRaw = Array.isArray(data.social_checkins) ? data.social_checkins : []
    const lodgeCheckinsRaw = Array.isArray(data.lodge_checkins) ? data.lodge_checkins : []
    executionLodgeTick.value = normalizeExecutionLodgeTick(data.social_tick ?? data.lodge_tick)
    executionLodgeCheckins.value = (socialCheckinsRaw.length > 0 ? socialCheckinsRaw : lodgeCheckinsRaw)
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

export * from './store-normalizers'
