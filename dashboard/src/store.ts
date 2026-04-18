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
  BoardSortMode,
  Goal,
  DashboardExecutionSessionBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardExecutionResponse,
  DashboardConfigResolution,
  DashboardRuntimeResolution,
  DashboardShellAuthSummary,
  DashboardShellMetaCognitionSummary,
} from './types'
import {
  fetchDashboardExecution,
  fetchDashboardMemory,
  fetchDashboardPlanning,
  fetchDashboardShell,
} from './api'
import { journal } from './sse'
import { showToast } from './components/common/toast'
import {
  keeperFreshnessTs,
  normalizeKeepers,
} from './keeper-store-normalize'
import { buildAgentMotion, normalizeAgentKey, type AgentMotionSnapshot } from './components/common/agent-motion'
import { groupByKey } from './components/common/collection'
import { setArrayByKeyIfChanged } from './signal-utils'
import { FetchScheduler } from './lib/fetch-scheduler'
import { isRecord, asString, asNumber } from './components/common/normalize'
import {
  normalizeAgent, normalizeTask, normalizeMessage,
  normalizeExecutionWorkerSupportBrief,
  normalizeExecutionContinuityBrief,
  mergeMessages,
  normalizeServerStatus, mergeServerStatus,
  normalizeDashboardConfigResolution,
  normalizeDashboardRuntimeResolution,
  normalizeShellMetaCognitionSummary,
} from './store-normalizers'

// --- Shell counts (lightweight fallback from /dashboard/shell) ---

export interface ShellCounts {
  agents: number
  tasks: number
  keepers: number
  total_runtimes: number
  configured_keepers: number
}

export const shellCounts = signal<ShellCounts | null>(null)
export const shellMetaCognition = signal<DashboardShellMetaCognitionSummary | null>(null)
export const shellAuthSummary = signal<DashboardShellAuthSummary | null>(null)
export const shellConfigResolution = signal<DashboardConfigResolution | null>(null)
export const shellRuntimeResolution = signal<DashboardRuntimeResolution | null>(null)

// --- Core state signals ---

export const agents = signal<Agent[]>([])
export const tasks = signal<Task[]>([])
export const messages = signal<Message[]>([])
export const keepers = signal<Keeper[]>([])
export const serverStatus = signal<ServerStatus | null>(null)
export const executionLoaded = signal(false)
export const executionLoading = signal(false)
export const executionError = signal<string | null>(null)
export const executionSessionBriefs = signal<DashboardExecutionSessionBrief[]>([])
export const executionWorkerSupportBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])
export const executionContinuityBriefs = signal<DashboardExecutionContinuityBrief[]>([])

// --- Keeper heartbeat tracking (name -> last heartbeat timestamp ms) ---

export const keeperHeartbeats = signal<Map<string, number>>(new Map())

// --- Board state ---

export const boardPosts = signal<BoardPost[]>([])
export const boardSortMode = signal<BoardSortMode>('recent')
export const boardExcludeSystem = signal(true)
export const boardExcludeAutomation = signal(false)
/** Content-category filter: which categories to hide */
export const boardHiddenCategories = signal<Set<string>>(new Set(['system']))
export const boardAuthorFilter = signal('')
/** Number of posts currently loaded — the offset for the next page request. */
export const boardOffset = signal<number>(0)
/** true when the server indicates (or we optimistically believe) more posts are available. */
export const boardHasMore = signal<boolean>(true)
/** Server-reported total when known; null while has_more=true. */
export const boardTotal = signal<number | null>(null)
/** true while a loadMore (append) request is in flight. Distinct from boardLoading (initial/reset). */
export const boardLoadingMore = signal<boolean>(false)

export function removeBoardPost(postId: string | undefined): void {
  if (!postId) return
  const filtered = boardPosts.value.filter(p => p.id !== postId)
  if (filtered.length !== boardPosts.value.length) {
    boardPosts.value = filtered
    boardOffset.value = filtered.length
  }
}

// --- Goals state ---

export const goals = signal<Goal[]>([])
export const goalsLoading = signal(false)

// --- OAS monitoring state ---

import type { OasAgentEvent, OasHealthSummary, OasKeeperSnapshot } from './types/oas'

import {
  OAS_AGENT_EVENT_BUFFER,
  OAS_KEEPER_SNAPSHOT_MAX,
  HEARTBEAT_STALE_MS,
  SHELL_TTL_MS,
} from './config/constants'
import { RingBuffer } from './lib/ring-buffer'

const oasAgentEventsRing = new RingBuffer<OasAgentEvent>(OAS_AGENT_EVENT_BUFFER)
export const oasAgentEvents = signal<OasAgentEvent[]>([])
export const oasKeeperSnapshots = signal<Map<string, OasKeeperSnapshot>>(new Map())
export const oasLastKeeperTick = signal<number | null>(null)
export const oasTotalEvents = signal(0)
export const oasTotalLlmCalls = signal(0)
export const oasTotalErrors = signal(0)
export const oasLastLlmCallTs = signal<number | null>(null)
export const oasLastErrorTs = signal<number | null>(null)

export function resetOasRuntimeSignals(): void {
  oasAgentEventsRing.clear()
  oasAgentEvents.value = []
  oasKeeperSnapshots.value = new Map()
  oasLastKeeperTick.value = null
  oasTotalEvents.value = 0
  oasTotalLlmCalls.value = 0
  oasTotalErrors.value = 0
  oasLastLlmCallTs.value = null
  oasLastErrorTs.value = null
}

function sameOasAgentEvent(left: OasAgentEvent, right: OasAgentEvent): boolean {
  if (left.event_key != null && right.event_key != null) {
    return left.event_key === right.event_key
  }
  if (
    left.type !== right.type
    || left.agent_name !== right.agent_name
    || left.timestamp !== right.timestamp
  ) {
    return false
  }
  switch (left.type) {
    case 'selected':
      return (
        right.type === 'selected'
        && left.trigger === right.trigger
        && left.thompson_score === right.thompson_score
        && left.final_score === right.final_score
      )
    case 'decision':
      return (
        right.type === 'decision'
        && left.action === right.action
        && left.trigger_reason === right.trigger_reason
      )
    case 'action_executed':
      return (
        right.type === 'action_executed'
        && left.action === right.action
        && left.success === right.success
      )
    case 'keeper_lifecycle':
      return (
        right.type === 'keeper_lifecycle'
        && left.keeper_name === right.keeper_name
        && left.event === right.event
        && left.phase === right.phase
        && left.detail === right.detail
      )
    case 'trust_updated':
      return (
        right.type === 'trust_updated'
        && left.secondary_agent === right.secondary_agent
        && left.trust_score === right.trust_score
      )
    case 'reputation_changed':
      return (
        right.type === 'reputation_changed'
        && left.old_score === right.old_score
        && left.new_score === right.new_score
        && left.trend === right.trend
      )
  }
}

export function pushOasAgentEvent(event: OasAgentEvent): void {
  const head = oasAgentEventsRing.peek()
  if (head != null && sameOasAgentEvent(head, event)) {
    return
  }
  oasAgentEventsRing.push(event)
  oasAgentEvents.value = oasAgentEventsRing.toArray() as OasAgentEvent[]
}

/** Record an OAS durable LLM-call event. Increments the global
 *  counter and pins the latest timestamp so the runtime panel can
 *  surface recency. */
export function recordOasLlmCall(tsMs: number): void {
  oasTotalLlmCalls.value++
  oasLastLlmCallTs.value = Math.max(oasLastLlmCallTs.value ?? 0, tsMs)
}

/** Record an OAS durable error event. */
export function recordOasError(tsMs: number): void {
  oasTotalErrors.value++
  oasLastErrorTs.value = Math.max(oasLastErrorTs.value ?? 0, tsMs)
}

export function updateOasKeeperSnapshot(snapshot: OasKeeperSnapshot): void {
  const next = new Map<string, OasKeeperSnapshot>(oasKeeperSnapshots.value)
  next.set(snapshot.keeper_name, snapshot)
  // Prune oldest if exceeding max
  if (next.size > OAS_KEEPER_SNAPSHOT_MAX) {
    let oldest: string | null = null
    let oldestTs = Infinity
    for (const [name, snap] of next) {
      if (snap.timestamp < oldestTs) {
        oldest = name
        oldestTs = snap.timestamp
      }
    }
    if (oldest) next.delete(oldest)
  }
  oasKeeperSnapshots.value = next
  if (Number.isFinite(snapshot.timestamp)) {
    const nextTickMs = Math.round(snapshot.timestamp * 1000)
    oasLastKeeperTick.value = Math.max(oasLastKeeperTick.value ?? 0, nextTickMs)
  }
}

export const oasHealthSummary: ReadonlySignal<OasHealthSummary> = computed(() => ({
  agentEventsCount: oasAgentEvents.value.length,
  keeperSnapshotsCount: oasKeeperSnapshots.value.size,
  lastKeeperTick: oasLastKeeperTick.value,
  totalEvents: oasTotalEvents.value,
  totalLlmCalls: oasTotalLlmCalls.value,
  totalErrors: oasTotalErrors.value,
  lastLlmCallTs: oasLastLlmCallTs.value,
  lastErrorTs: oasLastErrorTs.value,
}))

// --- Loading flags ---

export const dashboardLoading = signal(false)
export const boardLoading = signal(false)

// --- Refresh timestamps ---

export const lastBoardRefreshAt = signal<string | null>(null)
export const lastGoalsRefreshAt = signal<string | null>(null)

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

  // Pre-index: one pass per array — O(N) total instead of O(N * agents)
  const tasksByAgent = groupByKey(taskList, t => normalizeAgentKey(t.assignee))
  const messagesByAgent = groupByKey(messageList, m => normalizeAgentKey(m.from ?? ''))
  const journalByAgent = groupByKey(journalList, e => normalizeAgentKey(e.agent))
  const journalByAuthor = groupByKey(journalList, e => normalizeAgentKey(e.author))
  const boardByAgent = groupByKey(boardPostList, p => normalizeAgentKey(p.author))
  const keepersByAgent = groupByKey(keeperList, k => normalizeAgentKey(k.name))

  for (const agent of agents.value) {
    const key = normalizeAgentKey(agent.name)
    // Merge journal entries matched by agent OR author (deduplicate)
    const agentJournal = journalByAgent.get(key) ?? []
    const authorJournal = journalByAuthor.get(key) ?? []
    const mergedJournal = agentJournal.length === 0
      ? authorJournal
      : authorJournal.length === 0
        ? agentJournal
        : agentJournal.concat(authorJournal)

    map.set(
      key,
      buildAgentMotion(
        tasksByAgent.get(key) ?? [],
        messagesByAgent.get(key) ?? [],
        mergedJournal,
        {
          currentTask: agent.current_task,
          lastSeen: agent.last_seen,
          boardPosts: boardByAgent.get(key) ?? [],
          keepers: keepersByAgent.get(key) ?? [],
        },
      ),
    )
  }
  return map
})

// Heartbeat staleness threshold — value from config/constants.ts

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

interface RefreshOptions {
  force?: boolean
}

// TTL values from config/constants.ts

let inflightDashboardRefresh: Promise<void> | null = null
let inflightShellRefresh: Promise<void> | null = null
let lastShellRefreshAt = 0

export function invalidateDashboardCache(): void {
  // Projection endpoints are intentionally fresh-first after the operator-console rewrite.
}

export async function refreshDashboard(opts?: RefreshOptions): Promise<void> {
  if (inflightDashboardRefresh) return inflightDashboardRefresh
  dashboardLoading.value = true
  inflightDashboardRefresh = (async () => {
    try {
      await Promise.all([refreshShell(opts), refreshExecution(opts)])
    } catch (err) {
      console.warn('[Dashboard] refresh error:', err)
    } finally {
      dashboardLoading.value = false
      inflightDashboardRefresh = null
    }
  })()
  return inflightDashboardRefresh
}

function applyPlanningEnvelope(data: {
  goals?: unknown[]
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
}

function normalizeShellAuthSummary(raw: unknown): DashboardShellAuthSummary | null {
  if (!isRecord(raw)) return null
  return {
    enabled: raw.enabled === true,
    require_token: raw.require_token === true,
    default_role: asString(raw.default_role) ?? null,
    token_present: raw.token_present === true,
    requested_agent: asString(raw.requested_agent) ?? null,
    effective_agent: asString(raw.effective_agent) ?? null,
    effective_role: asString(raw.effective_role) ?? null,
    can_keeper_msg: raw.can_keeper_msg === true,
    keeper_msg_error: asString(raw.keeper_msg_error) ?? null,
  }
}

export async function refreshShell(opts?: RefreshOptions): Promise<void> {
  if (inflightShellRefresh) return inflightShellRefresh
  if (!opts?.force && Date.now() - lastShellRefreshAt < SHELL_TTL_MS) return
  inflightShellRefresh = (async () => {
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
          total_runtimes: data.counts.total_runtimes ?? ((data.counts.agents ?? 0) + (data.counts.keepers ?? 0)),
          configured_keepers: data.configured_keepers ?? 0,
        }
      }
      shellMetaCognition.value = normalizeShellMetaCognitionSummary(data.meta_cognition)
      shellAuthSummary.value = normalizeShellAuthSummary(data.auth)
      shellConfigResolution.value = normalizeDashboardConfigResolution(data.config_resolution)
      shellRuntimeResolution.value = normalizeDashboardRuntimeResolution(data.runtime_resolution)
      lastShellRefreshAt = Date.now()
    } catch (err) {
      console.warn('[Dashboard] shell fetch error:', err)
      showToast('서버 연결 실패 — 데이터를 불러올 수 없습니다', 'error', 6000)
    } finally {
      inflightShellRefresh = null
    }
  })()
  return inflightShellRefresh
}

/** Hydrate all execution-related signals from a raw data payload.
 *  Shared by doFetchExecution (HTTP) and SSE execution_snapshot handler. */
export function hydrateExecutionSnapshot(data: DashboardExecutionResponse): void {
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  const previousProject = serverStatus.value?.project
  if (normalizedStatus) {
    serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  }
  const roomChanged =
    previousProject != null
    && normalizedStatus?.project != null
    && previousProject !== normalizedStatus.project
  const normalizedAgents = (Array.isArray(data.agents) ? data.agents : [])
    .map(normalizeAgent)
    .filter((row): row is Agent => row !== null)
  setArrayByKeyIfChanged(agents, normalizedAgents, a => a.name)
  const normalizedTasks = (Array.isArray(data.tasks) ? data.tasks : [])
    .map(normalizeTask)
    .filter((row): row is Task => row !== null)
  setArrayByKeyIfChanged(tasks, normalizedTasks, t => `${t.id}:${t.status ?? ''}`)
  const executionMessages = (Array.isArray(data.messages) ? data.messages : [])
    .map(normalizeMessage)
    .filter((row): row is Message => row !== null)
  messages.value = roomChanged ? executionMessages : mergeMessages(messages.value, executionMessages)
  keepers.value = normalizeKeepers(data.keepers)
  const normalizedWorkerBriefs = (Array.isArray(data.worker_support_briefs) ? data.worker_support_briefs : Array.isArray(data.worker_briefs) ? data.worker_briefs : [])
    .map(normalizeExecutionWorkerSupportBrief)
    .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
  setArrayByKeyIfChanged(executionWorkerSupportBriefs, normalizedWorkerBriefs, w => w.name)
  const normalizedContinuityBriefs = (Array.isArray(data.continuity_briefs) ? data.continuity_briefs : [])
    .map(normalizeExecutionContinuityBrief)
    .filter((row): row is DashboardExecutionContinuityBrief => row !== null)
  setArrayByKeyIfChanged(executionContinuityBriefs, normalizedContinuityBriefs, c => c.name)
  executionLoaded.value = true
}

async function doFetchExecution(): Promise<void> {
  executionLoading.value = true
  executionError.value = null
  try {
    const data = await fetchDashboardExecution()
    hydrateExecutionSnapshot(data)
  } catch (err) {
    console.warn('[Dashboard] execution fetch error:', err)
    executionError.value = err instanceof Error ? err.message : 'Execution projection load failed'
    showToast('실행 데이터 로드 실패', 'error', 5000)
  } finally {
    executionLoading.value = false
  }
}

const executionScheduler = new FetchScheduler(doFetchExecution, {
  cooldownMs: 2_000,
  debounceMs: 300,
})

export async function refreshExecution(opts?: RefreshOptions): Promise<void> {
  if (opts?.force) {
    executionScheduler.requestNow()
  } else {
    executionScheduler.request()
  }
  if (executionScheduler.inflightPromise) {
    await executionScheduler.inflightPromise
  }
}

/** Reconcile board posts by id+updated_at so unchanged items keep
 *  the same object reference.  Preact skips re-rendering subtrees
 *  whose props haven't changed, preserving scroll position. */
function sameStringArray(a: string[] | undefined, b: string[] | undefined): boolean {
  const left = a ?? []
  const right = b ?? []
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function canReuseBoardPost(previous: BoardPost, next: BoardPost): boolean {
  return previous.updated_at === next.updated_at
    && previous.votes === next.votes
    && previous.vote_balance === next.vote_balance
    && previous.comment_count === next.comment_count
    && previous.post_kind === next.post_kind
    && previous.classification_reason === next.classification_reason
    && previous.title === next.title
    && previous.body === next.body
    && previous.content === next.content
    && previous.flair === next.flair
    && previous.hearth === next.hearth
    && previous.visibility === next.visibility
    && previous.expires_at === next.expires_at
    && sameStringArray(previous.tags, next.tags)
    && (previous.meta?.source ?? null) === (next.meta?.source ?? null)
    && (previous.meta?.state_block ?? null) === (next.meta?.state_block ?? null)
}

export function reconcileBoardPosts(prev: BoardPost[], next: BoardPost[]): BoardPost[] {
  if (prev.length === 0) return next
  const prevById = new Map(prev.map(p => [p.id, p]))
  let changed = prev.length !== next.length
  const merged = next.map((n, index) => {
    const old = prevById.get(n.id)
    if (!changed && prev[index]?.id !== n.id) {
      changed = true
    }
    if (old && canReuseBoardPost(old, n)) {
      return old
    }
    changed = true
    return n
  })
  return changed ? merged : prev
}

/** Append incoming posts to the tail, de-duplicated by id. */
export function appendBoardPosts(prev: BoardPost[], incoming: BoardPost[]): BoardPost[] {
  if (incoming.length === 0) return prev
  if (prev.length === 0) return incoming
  const existing = new Set(prev.map(p => p.id))
  const fresh = incoming.filter(p => !existing.has(p.id))
  if (fresh.length === 0) return prev
  return prev.concat(fresh)
}

const BOARD_PAGE_SIZE_DEFAULT = 100
const BOARD_PAGE_SIZE_FILTERED = 200

function boardPageSize(): number {
  const hasFilter =
    boardExcludeAutomation.value
    || boardExcludeSystem.value
    || boardAuthorFilter.value.trim() !== ''
  return hasFilter ? BOARD_PAGE_SIZE_FILTERED : BOARD_PAGE_SIZE_DEFAULT
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const limit = boardPageSize()
    const data = await fetchDashboardMemory(boardSortMode.value, {
      excludeSystem: boardExcludeSystem.value,
      excludeAutomation: boardExcludeAutomation.value,
      author: boardAuthorFilter.value || undefined,
      limit,
      offset: 0,
    })
    const next = data.posts ?? []
    boardPosts.value = reconcileBoardPosts(boardPosts.value, next)
    boardOffset.value = next.length
    boardHasMore.value = typeof data.has_more === 'boolean'
      ? data.has_more
      : next.length >= limit
    boardTotal.value = typeof data.total === 'number' ? data.total : null
    lastBoardRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.warn('[Board] fetch error:', err)
    showToast('게시판을 불러오지 못했습니다', 'error')
  } finally {
    boardLoading.value = false
  }
}

/** Append the next page of board posts onto boardPosts. Noop if a request is
 *  already in flight or the server indicated no more pages. */
export async function loadMoreBoardPosts(): Promise<void> {
  if (boardLoadingMore.value || boardLoading.value) return
  if (!boardHasMore.value) return
  boardLoadingMore.value = true
  try {
    const limit = boardPageSize()
    const offset = boardOffset.value
    const data = await fetchDashboardMemory(boardSortMode.value, {
      excludeSystem: boardExcludeSystem.value,
      excludeAutomation: boardExcludeAutomation.value,
      author: boardAuthorFilter.value || undefined,
      limit,
      offset,
    })
    const incoming = data.posts ?? []
    const merged = appendBoardPosts(boardPosts.value, incoming)
    boardPosts.value = merged
    boardOffset.value = merged.length
    boardHasMore.value = typeof data.has_more === 'boolean'
      ? data.has_more
      : incoming.length >= limit
    boardTotal.value = typeof data.total === 'number' ? data.total : null
  } catch (err) {
    console.warn('[Board] loadMore error:', err)
    showToast('다음 페이지를 불러오지 못했습니다', 'error')
  } finally {
    boardLoadingMore.value = false
  }
}

// --- Goals fetcher ---

export async function refreshGoals(): Promise<void> {
  goalsLoading.value = true
  try {
    const data = await fetchDashboardPlanning()
    applyPlanningEnvelope(data)
    lastGoalsRefreshAt.value = new Date().toISOString()
  } catch (err) {
    console.warn('[Planning] fetch error:', err)
  } finally {
    goalsLoading.value = false
  }
}

export * from './store-normalizers'
