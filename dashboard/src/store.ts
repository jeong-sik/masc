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
  RefreshOptions,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardExecutionResponse,
  DashboardBootstrapResponse,
  DashboardBootstrapSliceError,
  DashboardMemoryResponse,
  DashboardPlanningResponse,
  DashboardConfigResolution,
  DashboardRuntimeResolution,
  DashboardShellAuthSummary,
  DashboardShellResponse,
} from './types'
import { fetchDashboardBootstrap, fetchDashboardShell } from './api/dashboard-hot'
import { journal } from './sse'
import { showToast } from './components/common/toast'
import { errorMessageOr } from './lib/format-string'
import { isAbortError } from './lib/async-state'
import {
  keeperFreshnessTs,
  normalizeKeepers,
} from './keeper-store-normalize'
import { buildAgentMotion, normalizeAgentKey, type AgentMotionSnapshot } from './components/common/agent-motion'
import {
  keeperIdentityKeys,
  keeperPrincipalKey,
} from './components/common/keeper-identity'
import { groupByKey } from './components/common/collection'
import { setArrayByKeyIfChanged } from './signal-utils'
import { FetchScheduler } from './lib/fetch-scheduler'
import { WARM_MAX_RETRIES, warmRetryDelayFor } from './lib/warm-retry'
import { isRecord, asString, asNumber } from './components/common/normalize'
import { setCanonicalDashboardActor } from './lib/dashboard-session-actor'
import { refreshDevTokenAfterAuthError } from './api/dev-token'
import { timeBoardRequest } from './board-metrics'
import { namespaceTruth, namespaceTruthError, namespaceTruthInitializing } from './namespace-truth-signals'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'
import {
  goalTreeData,
  goalTreeError,
  goalTreeLoading,
  hydrateGoalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from './goal-tree-state'
import {
  WORK_GOAL_LOAD_ERROR,
  WORK_GOAL_LOAD_PARTIAL_ERROR,
  WORK_GOAL_TOAST_DURATION_MS,
} from './lib/work-copy'
import {
  normalizeAgent, normalizeTask, normalizeMessage,
  normalizeExecutionWorkerSupportBrief,
  normalizeExecutionContinuityBrief,
  mergeMessages,
  normalizeServerStatus, mergeServerStatus,
  normalizeDashboardConfigResolution,
  normalizeDashboardRuntimeResolution,
} from './store-normalizers'

// --- Shell counts (lightweight fallback from /dashboard/shell) ---

interface ShellCounts {
  agents?: number
  tasks?: number
  keepers?: number
  total_runtimes?: number
  configured_keepers?: number
}

export const shellCounts = signal<ShellCounts | null>(null)
export const shellAuthSummary = signal<DashboardShellAuthSummary | null>(null)
export const shellConfigResolution = signal<DashboardConfigResolution | null>(null)
export const shellRuntimeResolution = signal<DashboardRuntimeResolution | null>(null)

// --- Core state signals ---

export const agents = signal<Agent[]>([])
export const tasks = signal<Task[]>([])
export const messages = signal<Message[]>([])
export const workspaceMessagesLoading = signal(false)
export const workspaceMessagesError = signal<string | null>(null)
export const keepers = signal<Keeper[]>([])

// Names whose purge the server accepted but has not finished. Purge answers
// 202 with an operation id and deletes asynchronously, so the refresh that
// follows the submit still returns the keeper — without this the row redraws
// unchanged and the operator sees nothing happen.
//
// A typed Purged lifecycle event does exist and is already projected: the
// server publishes it at completion and the execution surface maps it to
// phase="stopped" (server_dashboard_http_execution_surfaces.ml). What is
// missing is a projection that REMOVES the row rather than patching it, and a
// keeper-row field carrying the durable shutdown-operation phase so a purge
// that blocks after acceptance becomes visible. Until then the name's
// disappearance from a refresh is the signal available here — which is why the
// button below stays clickable rather than gating on this marker.
export const keeperPurgePending = signal<ReadonlySet<string>>(new Set<string>())

export function markKeeperPurgePending(name: string): void {
  const trimmed = name.trim()
  if (trimmed === '' || keeperPurgePending.value.has(trimmed)) return
  keeperPurgePending.value = new Set([...keeperPurgePending.value, trimmed])
}

/** A pending name survives a refresh only while the refresh still returns it.
 *  Once the server has finished deleting, the keeper drops out of the payload
 *  and the name leaves the set — that disappearance is the completion signal. */
export function purgePendingAfterRefresh(
  pending: ReadonlySet<string>,
  rows: readonly { name: string }[],
): ReadonlySet<string> {
  if (pending.size === 0) return pending
  const present = new Set(rows.map(row => row.name))
  const survivors = [...pending].filter(name => present.has(name))
  return survivors.length === pending.size ? pending : new Set(survivors)
}

function prunePurgePendingAgainst(rows: readonly Keeper[]): void {
  const next = purgePendingAfterRefresh(keeperPurgePending.value, rows)
  if (next !== keeperPurgePending.value) keeperPurgePending.value = next
}
export const serverStatus = signal<ServerStatus | null>(null)
// Authoritative backlog size from the execution payload's `task_counts.total`.
// The `tasks` signal holds only what the payload chose to send — active rows
// plus a bounded window of recent terminal ones — so counting it understates a
// tile labelled 전체 작업, most visibly for cancellations, which leave the
// window and then appear nowhere. Null when the payload omits the count.
export const executionTaskTotal = signal<number | null>(null)
export const executionLoaded = signal(false)
export const executionLoading = signal(false)
export const executionError = signal<string | null>(null)
export const executionWorkerSupportBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])
export const executionContinuityBriefs = signal<DashboardExecutionContinuityBrief[]>([])

// --- Keeper heartbeat tracking (name -> last heartbeat timestamp ms) ---

export const keeperHeartbeats = signal<Map<string, number>>(new Map())

// --- Cross-zone keeper filter (Phase 2 · I0-B) ---
// Empty set means "all keepers". Components that consume the filter
// should treat `size === 0` as the unconstrained case so the default
// route stays the broadest view. Adding a keeper id narrows the scope.
export const selectedKeeperFilter = signal<Set<string>>(new Set())

export type OptimisticKeeperDirective = 'pause' | 'resume' | 'wakeup'

function patchForDirective(action: OptimisticKeeperDirective): Partial<Keeper> {
  // `lifecycle_phase` is the field the roster status dot renders
  // (keeper-workspace-roster.ts → phaseTone/phasePulse(keeper.lifecycle_phase),
  // phaseText → lifecycle_phase ?? phase). Patching only `phase` left the
  // left-list dot stale until the server snapshot arrived, which read as
  // "status reflects very late" after resume/pause. Patch both so the dot
  // flips with the same click that flips the action buttons.
  switch (action) {
    case 'pause':
      return { paused: true, phase: 'Paused', lifecycle_phase: 'Paused', pipeline_stage: 'paused', status: 'paused' }
    case 'resume':
      return { paused: false, phase: 'Running', lifecycle_phase: 'Running', pipeline_stage: 'idle', status: 'idle' }
    case 'wakeup':
      return {}
  }
}

/** Optimistically apply a directive's expected state to the local
 *  `keepers` signal. Returns a `revert` thunk the caller must invoke
 *  on failure. If the keeper isn't in the local list the call is a
 *  no-op and `revert` is a no-op too. */
export function applyOptimisticKeeperDirective(
  name: string,
  action: OptimisticKeeperDirective,
): () => void {
  const before = keepers.value
  const idx = before.findIndex(k => k.name === name)
  if (idx === -1) return () => {}
  const original = before[idx]!
  const patch = patchForDirective(action)
  const updated: Keeper = { ...original, ...patch }
  keepers.value = [...before.slice(0, idx), updated, ...before.slice(idx + 1)]
  return () => {
    const current = keepers.value
    const cIdx = current.findIndex(k => k.name === name)
    if (cIdx === -1) return
    keepers.value = [...current.slice(0, cIdx), original, ...current.slice(cIdx + 1)]
  }
}

/** Bulk variant: apply the patch to each name, returning a per-name
 *  revert map so a caller seeing partial-failure can revert only the
 *  keepers the server reported failed. */
export function applyOptimisticKeeperDirectives(
  names: readonly string[],
  action: OptimisticKeeperDirective,
): Map<string, () => void> {
  const reverts = new Map<string, () => void>()
  for (const name of names) {
    reverts.set(name, applyOptimisticKeeperDirective(name, action))
  }
  return reverts
}

const KEEPER_RELATIVE_AGE_FIELDS = new Set<string>([
  'keeper_age_s',
  'last_activity_ago_s',
  'last_turn_ago_s',
  'last_handoff_ago_s',
  'last_proactive_ago_s',
])

function relativeAgeRenderBucket(value: unknown): unknown {
  if (value == null) return null
  if (typeof value !== 'number' || !Number.isFinite(value)) return value
  const seconds = Math.max(0, value)
  const bucketSeconds =
    seconds < 60
      ? 10
      : seconds < 3_600
        ? 60
        : 300
  return Math.floor(seconds / bucketSeconds)
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function stableValueEqual(left: unknown, right: unknown, key?: string): boolean {
  if (key && KEEPER_RELATIVE_AGE_FIELDS.has(key)) {
    return relativeAgeRenderBucket(left) === relativeAgeRenderBucket(right)
  }
  if (Object.is(left, right)) return true
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false
    if (left.length !== right.length) return false
    return left.every((value, index) => stableValueEqual(value, right[index]))
  }
  if (isPlainRecord(left) || isPlainRecord(right)) {
    if (!isPlainRecord(left) || !isPlainRecord(right)) return false
    const keys = new Set([...Object.keys(left), ...Object.keys(right)])
    for (const key of keys) {
      if (!stableValueEqual(left[key], right[key], key)) return false
    }
    return true
  }
  return false
}

function keeperRenderEqual(previous: Keeper, next: Keeper): boolean {
  const previousRecord = previous as unknown as Record<string, unknown>
  const nextRecord = next as unknown as Record<string, unknown>
  const keys = new Set([...Object.keys(previousRecord), ...Object.keys(nextRecord)])
  for (const key of keys) {
    if (KEEPER_RELATIVE_AGE_FIELDS.has(key)) {
      if (relativeAgeRenderBucket(previousRecord[key]) !== relativeAgeRenderBucket(nextRecord[key])) {
        return false
      }
      continue
    }
    if (!stableValueEqual(previousRecord[key], nextRecord[key], key)) return false
  }
  return true
}

/** Reconcile keeper rows so high-frequency execution snapshots do not
 *  recreate the whole roster/detail tree for clock-only drift.
 *
 *  The backend emits relative age fields as floating seconds, so every
 *  fresh snapshot can differ even when the keeper's actual state did not.
 *  Keep those fields at display-resolution while still updating immediately
 *  for status, lifecycle, model, goal, blocker, tool, and context changes.
 */
export function reconcileKeepers(previous: Keeper[], next: Keeper[]): Keeper[] {
  if (previous.length === 0) return next
  const previousByName = new Map(previous.map(keeper => [keeper.name, keeper]))
  let changed = previous.length !== next.length
  const merged = next.map((keeper, index) => {
    const old = previousByName.get(keeper.name)
    if (!changed && previous[index]?.name !== keeper.name) {
      changed = true
    }
    if (old && keeperRenderEqual(old, keeper)) {
      return old
    }
    changed = true
    return keeper
  })
  return changed ? merged : previous
}

// --- Board state ---

export const boardPosts = signal<BoardPost[]>([])
export const boardSortMode = signal<BoardSortMode>('recent')
export const boardExcludeSystem = signal(true)
export const boardExcludeAutomation = signal(false)
/** Content-category filter: which categories to hide */
export const boardHiddenCategories = signal<Set<string>>(new Set(['system']))
export const boardAuthorFilter = signal('')
export const boardHearthFilter = signal('')
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

// --- Fusion run registry state (RFC-0266 §7 Phase 4) ---

import type { FusionRunRecord } from './api/dashboard-fusion'

// In-progress + recently completed fusion deliberations from the in-memory
// registry endpoint. Distinct from `boardPosts` (the board-derived detail the
// FusionSurface already renders): the registry is the only source that shows a
// run while it is still `running`, before any board post exists.
export const fusionBoardPosts = signal<BoardPost[]>([])
export const fusionBoardLoading = signal(false)
export const fusionBoardError = signal<string | null>(null)
export const fusionRuns = signal<FusionRunRecord[]>([])
export const fusionRunsLoading = signal(false)
export const fusionRunsError = signal<string | null>(null)

// --- Agent Core monitoring state ---

import type { AgentCoreAgentEvent, AgentCoreHealthSummary } from './types/agent-core'

import {
  AGENT_CORE_AGENT_EVENT_BUFFER,
  keeperHeartbeatStaleMs,
  SHELL_TTL_MS,
} from './config/constants'
import { RingBuffer } from './lib/ring-buffer'

const agentCoreAgentEventsRing = new RingBuffer<AgentCoreAgentEvent>(AGENT_CORE_AGENT_EVENT_BUFFER)
export const agentCoreAgentEvents = signal<AgentCoreAgentEvent[]>([])
export const agentCoreTotalEvents = signal(0)
export const agentCoreReplayLoadedEvents = signal(0)
export const agentCoreReplayTotalMatchingEvents = signal(0)
export const agentCoreReplayTruncated = signal(false)
export const agentCoreReplayCapped = signal(false)
export const agentCoreTotalLlmCalls = signal(0)
export const agentCoreTotalErrors = signal(0)
export const agentCoreLastLlmCallTs = signal<number | null>(null)
export const agentCoreLastErrorTs = signal<number | null>(null)
export const agentCoreEvidenceRefsCount = signal(0)
export const agentCoreArtifactRefsCount = signal(0)
export const agentCoreRawTraceRefsCount = signal(0)
export const agentCoreReportRefsCount = signal(0)
export const agentCoreProofRefsCount = signal(0)
export const agentCoreTelemetryRefsCount = signal(0)
export const agentCoreRuntimeEvidenceRefsCount = signal(0)
export const agentCoreLastEvidenceTs = signal<number | null>(null)

export function resetAgentCoreRuntimeSignals(): void {
  agentCoreAgentEventsRing.clear()
  agentCoreAgentEvents.value = []
  agentCoreTotalEvents.value = 0
  agentCoreReplayLoadedEvents.value = 0
  agentCoreReplayTotalMatchingEvents.value = 0
  agentCoreReplayTruncated.value = false
  agentCoreReplayCapped.value = false
  agentCoreTotalLlmCalls.value = 0
  agentCoreTotalErrors.value = 0
  agentCoreLastLlmCallTs.value = null
  agentCoreLastErrorTs.value = null
  agentCoreEvidenceRefsCount.value = 0
  agentCoreArtifactRefsCount.value = 0
  agentCoreRawTraceRefsCount.value = 0
  agentCoreReportRefsCount.value = 0
  agentCoreProofRefsCount.value = 0
  agentCoreTelemetryRefsCount.value = 0
  agentCoreRuntimeEvidenceRefsCount.value = 0
  agentCoreLastEvidenceTs.value = null
}

export function noteAgentCoreReplayWindow(input: {
  loadedEvents: number
  totalMatchingEvents: number
  truncated: boolean
  capped?: boolean
  observedTotalEvents?: number
}): void {
  const loadedEvents = Math.max(0, Math.floor(input.loadedEvents))
  const totalMatchingEvents = Math.max(loadedEvents, Math.floor(input.totalMatchingEvents))
  const observedTotalEvents = Math.max(
    totalMatchingEvents,
    Math.floor(input.observedTotalEvents ?? totalMatchingEvents),
  )
  const truncated = input.truncated && totalMatchingEvents > loadedEvents
  const capped = Boolean(input.capped) && totalMatchingEvents > loadedEvents
  agentCoreReplayLoadedEvents.value = loadedEvents
  agentCoreReplayTotalMatchingEvents.value = totalMatchingEvents
  agentCoreReplayTruncated.value = truncated && !capped
  agentCoreReplayCapped.value = capped
  agentCoreTotalEvents.value = observedTotalEvents
}

function sameAgentCoreAgentEvent(left: AgentCoreAgentEvent, right: AgentCoreAgentEvent): boolean {
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
    case 'keeper_lifecycle':
      return (
        right.type === 'keeper_lifecycle'
        && left.keeper_name === right.keeper_name
        && left.event === right.event
        && left.phase === right.phase
        && left.detail === right.detail
      )
  }
}

export function pushAgentCoreAgentEvent(event: AgentCoreAgentEvent): void {
  const head = agentCoreAgentEventsRing.peek()
  if (head != null && sameAgentCoreAgentEvent(head, event)) {
    return
  }
  agentCoreAgentEventsRing.push(event)
  agentCoreAgentEvents.value = agentCoreAgentEventsRing.toArray() as AgentCoreAgentEvent[]
}

/** Record an Agent Core durable LLM-call event. Increments the global
 *  counter and pins the latest timestamp so the runtime panel can
 *  surface recency. */
export function recordAgentCoreLlmCall(tsMs: number): void {
  agentCoreTotalLlmCalls.value++
  agentCoreLastLlmCallTs.value = Math.max(agentCoreLastLlmCallTs.value ?? 0, tsMs)
}

/** Record an Agent Core durable error event. */
export function recordAgentCoreError(tsMs: number): void {
  agentCoreTotalErrors.value++
  agentCoreLastErrorTs.value = Math.max(agentCoreLastErrorTs.value ?? 0, tsMs)
}

export function recordAgentCoreEvidenceRefs(input: {
  evidenceRefsCount?: number
  artifactRefsCount?: number
  rawTraceRefsCount?: number
  reportRefsCount?: number
  proofRefsCount?: number
  telemetryRefsCount?: number
  runtimeEvidenceRefsCount?: number
  tsMs?: number | null
}): void {
  const evidenceRefsCount = Math.max(0, Math.floor(input.evidenceRefsCount ?? 0))
  const artifactRefsCount = Math.max(0, Math.floor(input.artifactRefsCount ?? 0))
  const rawTraceRefsCount = Math.max(0, Math.floor(input.rawTraceRefsCount ?? 0))
  const reportRefsCount = Math.max(0, Math.floor(input.reportRefsCount ?? 0))
  const proofRefsCount = Math.max(0, Math.floor(input.proofRefsCount ?? 0))
  const telemetryRefsCount = Math.max(0, Math.floor(input.telemetryRefsCount ?? 0))
  const runtimeEvidenceRefsCount = Math.max(0, Math.floor(input.runtimeEvidenceRefsCount ?? 0))
  if (
    evidenceRefsCount
    + artifactRefsCount
    + rawTraceRefsCount
    + reportRefsCount
    + proofRefsCount
    + telemetryRefsCount
    + runtimeEvidenceRefsCount === 0
  ) {
    return
  }
  agentCoreEvidenceRefsCount.value += evidenceRefsCount
  agentCoreArtifactRefsCount.value += artifactRefsCount
  agentCoreRawTraceRefsCount.value += rawTraceRefsCount
  agentCoreReportRefsCount.value += reportRefsCount
  agentCoreProofRefsCount.value += proofRefsCount
  agentCoreTelemetryRefsCount.value += telemetryRefsCount
  agentCoreRuntimeEvidenceRefsCount.value += runtimeEvidenceRefsCount
  if (typeof input.tsMs === 'number' && Number.isFinite(input.tsMs)) {
    agentCoreLastEvidenceTs.value = Math.max(agentCoreLastEvidenceTs.value ?? 0, input.tsMs)
  }
}

export const agentCoreHealthSummary: ReadonlySignal<AgentCoreHealthSummary> = computed(() => ({
  agentEventsCount: agentCoreAgentEvents.value.length,
  totalEvents: agentCoreTotalEvents.value,
  replayLoadedEvents: agentCoreReplayLoadedEvents.value,
  replayTotalMatchingEvents: agentCoreReplayTotalMatchingEvents.value,
  replayTruncated: agentCoreReplayTruncated.value,
  replayCapped: agentCoreReplayCapped.value,
  hasMore: agentCoreReplayTruncated.value,
  totalLlmCalls: agentCoreTotalLlmCalls.value,
  totalErrors: agentCoreTotalErrors.value,
  lastLlmCallTs: agentCoreLastLlmCallTs.value,
  lastErrorTs: agentCoreLastErrorTs.value,
  evidenceRefsCount: agentCoreEvidenceRefsCount.value,
  artifactRefsCount: agentCoreArtifactRefsCount.value,
  rawTraceRefsCount: agentCoreRawTraceRefsCount.value,
  reportRefsCount: agentCoreReportRefsCount.value,
  proofRefsCount: agentCoreProofRefsCount.value,
  telemetryRefsCount: agentCoreTelemetryRefsCount.value,
  runtimeEvidenceRefsCount: agentCoreRuntimeEvidenceRefsCount.value,
  lastEvidenceTs: agentCoreLastEvidenceTs.value,
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
    awaitingVerification: all.filter(t => t.status === 'awaiting_verification'),
    done: all.filter(t => t.status === 'done'),
  }
})

function keeperPrincipalLookup(keeperList: Keeper[]): Map<string, string> {
  const lookup = new Map<string, string>()
  for (const keeper of keeperList) {
    const principal =
      keeperPrincipalKey(keeper.keeper_id, keeper.name)
      ?? normalizeAgentKey(keeper.name)
    for (const key of keeperIdentityKeys(keeper.keeper_id, keeper.name)) {
      lookup.set(normalizeAgentKey(key), principal)
    }
  }
  return lookup
}

function actorPrincipalKey(
  value: string | null | undefined,
  lookup: ReadonlyMap<string, string>,
): string {
  const raw = normalizeAgentKey(value)
  if (!raw) return raw
  return lookup.get(raw) ?? raw
}

function boardPostPrincipalKey(
  post: BoardPost,
  lookup: ReadonlyMap<string, string>,
): string {
  const rawResolved = actorPrincipalKey(post.author, lookup)
  if (rawResolved !== normalizeAgentKey(post.author)) return rawResolved
  const projected = post.author_identity?.key
  return projected ? normalizeAgentKey(projected) : rawResolved
}

export const agentMotionMap: ReadonlySignal<Map<string, AgentMotionSnapshot>> = computed(() => {
  const map = new Map<string, AgentMotionSnapshot>()
  const taskList = tasks.value
  const messageList = messages.value
  const journalList = journal.value
  const boardPostList = boardPosts.value
  const keeperList = keepers.value
  const keeperLookup = keeperPrincipalLookup(keeperList)

  // Pre-index: one pass per array — O(N) total instead of O(N * agents)
  const tasksByAgent = groupByKey(taskList, t => actorPrincipalKey(t.assignee, keeperLookup))
  const messagesByAgent = groupByKey(messageList, m => actorPrincipalKey(m.from ?? '', keeperLookup))
  const journalByAgent = groupByKey(journalList, e => actorPrincipalKey(e.agent, keeperLookup))
  const journalByAuthor = groupByKey(journalList, e => actorPrincipalKey(e.author, keeperLookup))
  const boardByAgent = groupByKey(boardPostList, p => boardPostPrincipalKey(p, keeperLookup))
  const keepersByAgent = groupByKey(
    keeperList,
    k => keeperPrincipalKey(k.keeper_id, k.name) ?? normalizeAgentKey(k.name),
  )

  for (const agent of agents.value) {
    const rawKey = normalizeAgentKey(agent.name)
    const key = actorPrincipalKey(agent.name, keeperLookup)
    // Merge journal entries matched by agent OR author (deduplicate)
    const agentJournal = journalByAgent.get(key) ?? []
    const authorJournal = journalByAuthor.get(key) ?? []
    const mergedJournal = agentJournal.length === 0
      ? authorJournal
      : authorJournal.length === 0
        ? agentJournal
        : agentJournal.concat(authorJournal)

    const snapshot = buildAgentMotion(
      tasksByAgent.get(key) ?? [],
      messagesByAgent.get(key) ?? [],
      mergedJournal,
      {
        currentTask: agent.current_task,
        lastSeen: agent.last_seen,
        boardPosts: boardByAgent.get(key) ?? [],
        keepers: keepersByAgent.get(key) ?? [],
      },
    )
    map.set(rawKey, snapshot)
    map.set(key, snapshot)
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
    if (lastTs != null && (now - lastTs) > keeperHeartbeatStaleMs(k.heartbeat_stale_after_s)) {
      stale.add(k.name)
    }
  }
  return stale
})

// --- Refresh orchestration ---

// RefreshOptions imported from types/core.ts (SSOT)

// TTL values from config/constants.ts

let inflightDashboardRefresh: Promise<void> | null = null
let inflightShellRefresh: Promise<boolean> | null = null
let inflightShellRefreshLight = false
let inflightWorkspaceMessagesRefresh: Promise<void> | null = null
let inflightWorkspaceMessagesRefreshProject: string | null = null
let workspaceMessagesRefreshController: AbortController | null = null
let workspaceMessagesRefreshGeneration = 0
let workspaceMessagesRefreshInvalidated = false
// Once the dedicated workspace endpoint has committed a snapshot, execution
// payload messages are only a lower-fidelity fallback: they do not carry the
// producer request id or durable mention-delivery status.  Letting a later
// execution snapshot merge them back creates a second seq-identical row and
// can make an accepted delivery look pending again.
let workspaceMessagesDurableAuthority: { project: string | null } | null = null
let lastShellRefreshAt = 0

export function refreshDashboardWorkspaceMessages(
  expectedProject = serverStatus.value?.project ?? null,
): Promise<void> {
  if (inflightWorkspaceMessagesRefresh) {
    if (inflightWorkspaceMessagesRefreshProject === expectedProject) {
      workspaceMessagesRefreshInvalidated = true
      return inflightWorkspaceMessagesRefresh
    }
    // The inflight refresh targets a different project. Joining it would let
    // its result satisfy this call's expectedProject guard by coincidence;
    // abort it and start a fresh request scoped to this project instead.
    workspaceMessagesRefreshController?.abort()
  }

  workspaceMessagesLoading.value = true
  workspaceMessagesError.value = null
  workspaceMessagesRefreshInvalidated = false
  const generation = ++workspaceMessagesRefreshGeneration
  const controller = new AbortController()
  workspaceMessagesRefreshController = controller
  inflightWorkspaceMessagesRefreshProject = expectedProject
  inflightWorkspaceMessagesRefresh = (async () => {
    try {
      const { fetchDashboardWorkspaceMessages } = await import('./api/dashboard-workspace')
      let settled = false
      while (!settled && generation === workspaceMessagesRefreshGeneration) {
        workspaceMessagesRefreshInvalidated = false
        const nextMessages = await fetchDashboardWorkspaceMessages({
          signal: controller.signal,
        })
        if (generation !== workspaceMessagesRefreshGeneration || controller.signal.aborted) {
          return
        }
        if (workspaceMessagesRefreshInvalidated) {
          continue
        }
        if ((serverStatus.value?.project ?? null) === expectedProject) {
          // This endpoint is the durable Workspace message SSOT. Replace the
          // execution-derived cache instead of merging rows that the light
          // execution response intentionally omits.
          messages.value = nextMessages
          workspaceMessagesDurableAuthority = { project: expectedProject }
        }
        settled = true
      }
    } catch (error) {
      if (generation === workspaceMessagesRefreshGeneration && !isAbortError(error)) {
        // The durable endpoint failed after previously committing a snapshot
        // for this project: release authority so the execution-snapshot
        // fallback (see the comment above workspaceMessagesDurableAuthority's
        // declaration) can resume covering messages instead of freezing on
        // the last durable snapshot. Scoped to expectedProject so a stale
        // failure can't clear an authority a newer, still-inflight refresh
        // already set for a different project.
        if (workspaceMessagesDurableAuthority?.project === expectedProject) {
          workspaceMessagesDurableAuthority = null
        }
        workspaceMessagesError.value = errorMessageOr(
          error,
          'Workspace messages failed to load',
        )
        console.warn('[Workspace messages] fetch error:', error)
      }
    } finally {
      if (generation === workspaceMessagesRefreshGeneration) {
        workspaceMessagesLoading.value = false
        workspaceMessagesRefreshController = null
        inflightWorkspaceMessagesRefresh = null
        inflightWorkspaceMessagesRefreshProject = null
      }
    }
  })()
  return inflightWorkspaceMessagesRefresh
}

export function cancelDashboardWorkspaceMessagesRefresh(): void {
  workspaceMessagesRefreshGeneration += 1
  workspaceMessagesRefreshInvalidated = false
  workspaceMessagesRefreshController?.abort()
  workspaceMessagesRefreshController = null
  inflightWorkspaceMessagesRefresh = null
  inflightWorkspaceMessagesRefreshProject = null
  workspaceMessagesLoading.value = false
  // The durable refresh loop is no longer running, so its snapshot can no
  // longer be trusted to stay current — release authority so the
  // execution-snapshot fallback resumes covering messages.
  workspaceMessagesDurableAuthority = null
}

export function invalidateDashboardCache(): void {
  // Projection endpoints are intentionally fresh-first after the operator-console rewrite.
}

function bootstrapSliceError(slice: unknown): slice is DashboardBootstrapSliceError {
  return isRecord(slice) && typeof slice.error === 'string'
}

async function refreshDashboardFallback(opts?: RefreshOptions): Promise<void> {
  await Promise.all([refreshShell(opts), refreshExecution(opts)])
}

function hydrateDashboardBootstrap(
  data: DashboardBootstrapResponse,
  executionRequestGeneration: number,
): void {
  if (!data.shell || bootstrapSliceError(data.shell)) {
    throw new Error('dashboard bootstrap shell slice unavailable')
  }
  if (!data.execution || bootstrapSliceError(data.execution)) {
    throw new Error('dashboard bootstrap execution slice unavailable')
  }

  hydrateShellSnapshot(data.shell, { light: true })
  hydrateExecutionSnapshot(data.execution, { requestGeneration: executionRequestGeneration })

  if (data.planning && !bootstrapSliceError(data.planning)) {
    hydratePlanningSnapshot(data.planning)
  }
  if (data.namespace_truth && !bootstrapSliceError(data.namespace_truth)) {
    const normalized = normalizeNamespaceTruth(data.namespace_truth)
    namespaceTruth.value = normalized
    namespaceTruthError.value = null
    namespaceTruthInitializing.value = false
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.root.status ?? null,
    )
  }
  if (data.goals && !bootstrapSliceError(data.goals)) {
    if (!hydrateGoalTreeSnapshot(data.goals)) {
      hydrateGoalTreeObservationError(
        new Error('Goal Store tree payload was malformed'),
      )
    }
  }
}

export async function refreshDashboard(opts?: RefreshOptions): Promise<void> {
  if (inflightDashboardRefresh) return inflightDashboardRefresh
  dashboardLoading.value = true
  inflightDashboardRefresh = (async () => {
    const executionRequestGeneration = executionSnapshotRequestGeneration()
    try {
      executionLoading.value = true
      executionError.value = null
      try {
        hydrateDashboardBootstrap(
          await fetchDashboardBootstrap(),
          executionRequestGeneration,
        )
      } catch (bootstrapErr) {
        console.warn('[Dashboard] bootstrap refresh failed, falling back:', bootstrapErr)
        await refreshDashboardFallback(opts)
      } finally {
        executionLoading.value = false
      }
    } catch (err) {
      console.warn('[Dashboard] refresh error:', err)
    } finally {
      dashboardLoading.value = false
      inflightDashboardRefresh = null
    }
  })()
  return inflightDashboardRefresh
}

function applyPlanningEnvelope(data: DashboardPlanningResponse): void {
  goals.value = (Array.isArray(data.goals) ? data.goals : [])
    .map((row): Goal | null => {
      if (!isRecord(row)) return null
      const id = asString(row.id)
      const title = asString(row.title)
      const phase = asString(row.phase)
      const createdAt = asString(row.created_at)
      const updatedAt = asString(row.updated_at)
      if (!id || !title || !phase || !createdAt || !updatedAt) return null
      return {
        id,
        title,
        metric: asString(row.metric) ?? null,
        target_value: asString(row.target_value) ?? null,
        due_date: asString(row.due_date) ?? null,
        priority: asNumber(row.priority) ?? 3,
        phase,
        last_review_note: asString(row.last_review_note) ?? null,
        last_review_at: asString(row.last_review_at) ?? null,
        created_at: createdAt,
        updated_at: updatedAt,
      }
    })
    .filter((row): row is Goal => row !== null)
}

export function hydratePlanningSnapshot(
  data: DashboardPlanningResponse,
  opts?: { markRefreshAt?: boolean },
): void {
  applyPlanningEnvelope(data)
  if (opts?.markRefreshAt !== false) {
    lastGoalsRefreshAt.value = data.generated_at ?? new Date().toISOString()
  }
}

function normalizeShellAuthSummary(raw: unknown): DashboardShellAuthSummary | null {
  if (!isRecord(raw)) return null
  return {
    enabled: raw.enabled === true,
    require_token: raw.require_token === true,
    token_present: raw.token_present === true,
    token_valid: raw.token_valid === true,
    token_agent: asString(raw.token_agent) ?? null,
    requested_agent: asString(raw.requested_agent) ?? null,
    effective_agent: asString(raw.effective_agent) ?? null,
    effective_role: asString(raw.effective_role) ?? null,
    auth_error_code: asString(raw.auth_error_code) as DashboardShellAuthSummary['auth_error_code'],
    auth_error_detail: asString(raw.auth_error_detail) ?? null,
    can_keeper_msg: raw.can_keeper_msg === true,
    keeper_msg_error: asString(raw.keeper_msg_error) ?? null,
  }
}

/* The shell reports a rejected credential inside the body of a 200 response
   — `token_valid: false` plus the typed `auth_error_code` — because the
   loopback read contract stays available to an unauthenticated caller. The
   MCP client recovers from a rejected token by inspecting the auth error
   envelope of a *failed* call (`api/mcp.ts`), so a tab whose traffic is the
   shell/bootstrap poll never reaches that path and re-sends the same
   rejected token for the life of the tab.

   Measured on the live fleet 2026-08-12: one browser session re-sent a
   single rejected token (`sha256[0:8] = 75598b82`) every 6 minutes across
   two server restarts, and the server answered each one with
   `[silent:dashboard_actor_fallback] outcome=error err_kind=token_mismatch`
   — 7 in the 33 minutes sampled, with no terminating condition.

   `refreshDevTokenAfterAuthError` owns the whole policy: it ignores codes
   that a new token cannot fix, refuses to touch a manually pasted token,
   deduplicates concurrent attempts, and reports failure when the refetched
   token is identical, so a token that is rejected for some other reason
   cannot drive a refresh loop. */
function recoverFromRejectedShellAuth(auth: DashboardShellAuthSummary | null): void {
  if (auth === null || auth.token_valid || !auth.token_present) return
  void refreshDevTokenAfterAuthError(auth.auth_error_code)
}

export function hydrateShellSnapshot(
  data: DashboardShellResponse,
  opts?: { light?: boolean; preserveAuth?: boolean },
): void {
  const wantsLight = opts?.light === true
  const preserveAuth = opts?.preserveAuth === true
  const normalizedAuth = normalizeShellAuthSummary(data.auth)
  if (!preserveAuth) {
    recoverFromRejectedShellAuth(normalizedAuth)
    setCanonicalDashboardActor(
      normalizedAuth?.token_valid
        ? normalizedAuth.effective_agent ?? normalizedAuth.token_agent ?? null
        : null,
    )
  }
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  if (normalizedStatus) {
    serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  }
  if (data.counts) {
    const agents = data.counts.agents
    const keepers = data.counts.keepers
    const totalRuntimes = data.counts.total_runtimes
      ?? (agents != null && keepers != null ? agents + keepers : undefined)
    shellCounts.value = {
      ...(agents != null ? { agents } : {}),
      ...(data.counts.tasks != null ? { tasks: data.counts.tasks } : {}),
      ...(keepers != null ? { keepers } : {}),
      ...(totalRuntimes != null ? { total_runtimes: totalRuntimes } : {}),
      ...(data.configured_keepers != null
        ? { configured_keepers: data.configured_keepers }
        : {}),
    }
  }
  if (!preserveAuth) {
    shellAuthSummary.value = normalizedAuth
  }
  const normalizedConfigResolution = normalizeDashboardConfigResolution(data.config_resolution)
  const normalizedRuntimeResolution = normalizeDashboardRuntimeResolution(data.runtime_resolution, data.generated_at)
  if (!wantsLight || normalizedConfigResolution) {
    shellConfigResolution.value = normalizedConfigResolution
  }
  if (!wantsLight || normalizedRuntimeResolution) {
    shellRuntimeResolution.value = normalizedRuntimeResolution
  }
  lastShellRefreshAt = Date.now()
}

export async function refreshShell(opts?: RefreshOptions): Promise<boolean> {
  const wantsLight = opts?.light === true
  if (inflightShellRefresh) {
    // A forced refresh must observe state established by the caller before
    // this invocation (notably Settings clearing the browser token). Joining
    // an older request could otherwise hydrate auth from the pre-clear token
    // and falsely report that the cleared state was rechecked.
    if (!opts?.force && (wantsLight || !inflightShellRefreshLight)) return inflightShellRefresh
    await inflightShellRefresh
    // Another waiter may have started the required follow-up refresh while
    // this caller resumed. Join it only when it fetches at least as much as
    // this caller asked for. A light follow-up does not satisfy a full
    // request, so a full waiter that joined one would resolve without ever
    // fetching the full shell surface it asked for.
    if (inflightShellRefresh && (wantsLight || !inflightShellRefreshLight)) {
      return inflightShellRefresh
    }
  }
  if (!opts?.force && Date.now() - lastShellRefreshAt < SHELL_TTL_MS) return true
  inflightShellRefreshLight = wantsLight
  inflightShellRefresh = (async () => {
    try {
      const data = await fetchDashboardShell({ light: wantsLight })
      hydrateShellSnapshot(data, { light: wantsLight })
      return true
    } catch (err) {
      setCanonicalDashboardActor(null)
      shellAuthSummary.value = null
      console.warn('[Dashboard] shell fetch error:', err)
      showToast('서버 연결 실패 — 데이터를 불러올 수 없습니다', 'error', 6000)
      return false
    } finally {
      inflightShellRefresh = null
      inflightShellRefreshLight = false
    }
  })()
  return inflightShellRefresh
}

let executionPublicationEpoch: string | null = null
let executionReconnectPreviousEpoch: string | null = null
let executionReconnectAwaitingHttp = false
const executionReconnectInvalidationFloors = new Map<string, number>()
let executionPublicationGenerationWatermark = -1
let executionHydrationRequestGeneration = 0
const retiredExecutionPublicationEpochs = new Set<string>()

function retireExecutionPublicationEpoch(epoch: string): void {
  retiredExecutionPublicationEpochs.add(epoch)
}

function executionSnapshotRequestGeneration(): number {
  return executionHydrationRequestGeneration
}

function executionPublicationIdentityOf(
  data: DashboardExecutionResponse,
): { epoch: string; generation: number } | null {
  const epoch = data.execution_publication_epoch
  const generation = data.execution_publication_generation
  return typeof epoch === 'string'
    && epoch.trim() !== ''
    && typeof generation === 'number'
    && Number.isSafeInteger(generation)
    && generation >= 0
    ? { epoch, generation }
    : null
}

export function invalidateExecutionSnapshotGeneration(
  epoch: string,
  generation: number,
): boolean {
  if (
    epoch.trim() === ''
    || !Number.isSafeInteger(generation)
    || generation < 0
    || retiredExecutionPublicationEpochs.has(epoch)
  ) return false
  if (executionReconnectAwaitingHttp) {
    executionReconnectInvalidationFloors.set(
      epoch,
      Math.max(executionReconnectInvalidationFloors.get(epoch) ?? -1, generation),
    )
    return true
  }
  if (executionPublicationEpoch !== epoch) {
    const previousEpoch = executionPublicationEpoch ?? executionReconnectPreviousEpoch
    if (previousEpoch !== null && previousEpoch !== epoch) {
      retireExecutionPublicationEpoch(previousEpoch)
    }
    executionPublicationEpoch = epoch
    executionReconnectPreviousEpoch = null
    executionPublicationGenerationWatermark = generation
    return true
  }
  executionPublicationGenerationWatermark = Math.max(
    executionPublicationGenerationWatermark,
    generation,
  )
  return true
}

export function resetExecutionSnapshotGeneration(): void {
  executionReconnectPreviousEpoch = executionPublicationEpoch
  executionPublicationEpoch = null
  executionPublicationGenerationWatermark = -1
  executionReconnectAwaitingHttp = true
  executionReconnectInvalidationFloors.clear()
  executionHydrationRequestGeneration += 1
}

/** Hydrate all execution-related signals from a raw data payload.
 *  Shared by doFetchExecution (HTTP) and SSE execution_snapshot handler. */
export function hydrateExecutionSnapshot(
  data: DashboardExecutionResponse,
  opts?: { requestGeneration?: number },
): boolean {
  if (
    opts?.requestGeneration !== undefined
    && opts.requestGeneration !== executionHydrationRequestGeneration
  ) {
    return false
  }
  const identity = executionPublicationIdentityOf(data)
  if (executionReconnectAwaitingHttp && opts?.requestGeneration === undefined) {
    return false
  }
  if (identity !== null && retiredExecutionPublicationEpochs.has(identity.epoch)) {
    return false
  }
  if (
    executionReconnectAwaitingHttp
    && (
      identity === null
      || (
        identity.generation
        < (executionReconnectInvalidationFloors.get(identity.epoch) ?? -1)
      )
    )
  ) {
    return false
  }
  if (
    executionPublicationEpoch !== null
    && (
      identity === null
      || identity.epoch !== executionPublicationEpoch
      || identity.generation < executionPublicationGenerationWatermark
    )
  ) {
    return false
  }
  if (identity !== null) {
    if (executionPublicationEpoch === null) {
      if (
        executionReconnectPreviousEpoch !== null
        && executionReconnectPreviousEpoch !== identity.epoch
      ) {
        retireExecutionPublicationEpoch(executionReconnectPreviousEpoch)
      }
      executionPublicationEpoch = identity.epoch
      executionReconnectPreviousEpoch = null
      executionReconnectAwaitingHttp = false
      executionReconnectInvalidationFloors.clear()
    }
    executionPublicationGenerationWatermark = Math.max(
      executionPublicationGenerationWatermark,
      identity.generation,
    )
  }
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  const previousProject = serverStatus.value?.project
  if (normalizedStatus) {
    serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  }
  const workspaceChanged =
    previousProject != null
    && normalizedStatus?.project != null
    && previousProject !== normalizedStatus.project
  if (workspaceChanged) {
    // cancelDashboardWorkspaceMessagesRefresh() releases
    // workspaceMessagesDurableAuthority itself.
    cancelDashboardWorkspaceMessagesRefresh()
  }
  const normalizedAgents = (Array.isArray(data.agents) ? data.agents : [])
    .map(normalizeAgent)
    .filter((row): row is Agent => row !== null)
  setArrayByKeyIfChanged(agents, normalizedAgents, a => a.name, stableValueEqual)
  const normalizedTasks = (Array.isArray(data.tasks) ? data.tasks : [])
    .map(normalizeTask)
    .filter((row): row is Task => row !== null)
  setArrayByKeyIfChanged(tasks, normalizedTasks, t => t.id, stableValueEqual)
  executionTaskTotal.value = isRecord(data.task_counts)
    ? asNumber(data.task_counts.total) ?? null
    : null
  const executionMessages = (Array.isArray(data.messages) ? data.messages : [])
    .map(normalizeMessage)
    .filter((row): row is Message => row !== null)
  const currentProject = serverStatus.value?.project ?? null
  const durableMessagesOwnCurrentProject =
    workspaceMessagesDurableAuthority?.project === currentProject
  if (!durableMessagesOwnCurrentProject) {
    messages.value = workspaceChanged
      ? executionMessages
      : mergeMessages(messages.value, executionMessages)
  }
  keepers.value = reconcileKeepers(keepers.value, normalizeKeepers(data.keepers))
  prunePurgePendingAgainst(keepers.value)
  const normalizedWorkerBriefs = (Array.isArray(data.worker_support_briefs) ? data.worker_support_briefs : Array.isArray(data.worker_briefs) ? data.worker_briefs : [])
    .map(normalizeExecutionWorkerSupportBrief)
    .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
  setArrayByKeyIfChanged(executionWorkerSupportBriefs, normalizedWorkerBriefs, w => w.name, stableValueEqual)
  const normalizedContinuityBriefs = (Array.isArray(data.continuity_briefs) ? data.continuity_briefs : [])
    .map(normalizeExecutionContinuityBrief)
    .filter((row): row is DashboardExecutionContinuityBrief => row !== null)
  setArrayByKeyIfChanged(executionContinuityBriefs, normalizedContinuityBriefs, c => c.name, stableValueEqual)
  executionLoaded.value = true
  return true
}

let nextExecutionForce = false

// A warm-up envelope carries no fleet. Hydrating it would reconcile the
// keeper list against [] and report the fleet as loaded-and-empty (the
// "일치하는 키퍼가 없습니다" screen 37s after a restart, 2026-08-22).
export function isInitializingExecutionPayload(data: DashboardExecutionResponse): boolean {
  return data.status?.project === 'initializing'
}

let executionWarmRetryAttempt = 0
let executionWarmRetryTimer: ReturnType<typeof setTimeout> | null = null

function scheduleExecutionWarmRetry(): void {
  executionWarmRetryAttempt += 1
  if (executionWarmRetryAttempt > WARM_MAX_RETRIES) {
    executionWarmRetryAttempt = 0
    executionError.value = 'Server warm-up timed out. Try refreshing.'
    return
  }
  const delayMs = warmRetryDelayFor(executionWarmRetryAttempt)
  if (executionWarmRetryTimer) clearTimeout(executionWarmRetryTimer)
  executionWarmRetryTimer = setTimeout(() => {
    executionWarmRetryTimer = null
    executionScheduler.requestNow()
  }, delayMs)
}

async function doFetchExecution(): Promise<void> {
  const force = nextExecutionForce
  nextExecutionForce = false
  const requestGeneration = executionSnapshotRequestGeneration()
  executionLoading.value = true
  executionError.value = null
  try {
    const { fetchDashboardExecution } = await import('./api/dashboard-execution')
    const data = await fetchDashboardExecution({ force })
    if (isInitializingExecutionPayload(data)) {
      scheduleExecutionWarmRetry()
      return
    }
    executionWarmRetryAttempt = 0
    hydrateExecutionSnapshot(data, { requestGeneration })
  } catch (err) {
    console.warn('[Dashboard] execution fetch error:', err)
    executionError.value = errorMessageOr(err, 'Execution projection load failed')
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
    nextExecutionForce = true
    executionScheduler.requestNow()
  } else if (opts?.immediate) {
    executionScheduler.requestNow()
  } else {
    executionScheduler.request()
  }
  if (executionScheduler.inflightPromise) {
    await executionScheduler.inflightPromise
  }
}

export async function refreshKeeperRuntimeStatus(opts?: RefreshOptions): Promise<void> {
  const force = opts?.force ?? true
  await refreshShell({ light: true, force })
  await refreshExecution({ force })
}

/** Reconcile board posts by id+updated_at so unchanged items keep
 *  the same object reference.  Preact skips re-rendering subtrees
 *  whose props haven't changed, preserving scroll position. */
function sameStringArray(a: string[] | undefined, b: string[] | undefined): boolean {
  const left = a ?? []
  const right = b ?? []
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function sameBoardAuthorIdentity(previous: BoardPost, next: BoardPost): boolean {
  const left = previous.author_identity
  const right = next.author_identity
  return (left?.kind ?? null) === (right?.kind ?? null)
    && (left?.id ?? null) === (right?.id ?? null)
    && (left?.key ?? null) === (right?.key ?? null)
    && (left?.display_name ?? null) === (right?.display_name ?? null)
    && (left?.raw ?? null) === (right?.raw ?? null)
}

function canReuseBoardPost(previous: BoardPost, next: BoardPost): boolean {
  return previous.updated_at === next.updated_at
    && previous.author === next.author
    && sameBoardAuthorIdentity(previous, next)
    && previous.votes === next.votes
    && previous.vote_balance === next.vote_balance
    && previous.comment_count === next.comment_count
    && previous.post_kind === next.post_kind
    && previous.pinned === next.pinned
    && previous.classification_reason === next.classification_reason
    && previous.title === next.title
    && previous.body === next.body
    && previous.flair === next.flair
    && previous.hearth === next.hearth
    && previous.visibility === next.visibility
    && previous.expires_at === next.expires_at
    && sameStringArray(previous.tags, next.tags)
    && (previous.meta?.source ?? null) === (next.meta?.source ?? null)
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
    || boardHearthFilter.value.trim() !== ''
  return hasFilter ? BOARD_PAGE_SIZE_FILTERED : BOARD_PAGE_SIZE_DEFAULT
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const { fetchDashboardMemory } = await import('./api/dashboard-execution')
    const limit = boardPageSize()
    const data = await timeBoardRequest('list', () => fetchDashboardMemory(boardSortMode.value, {
      excludeSystem: boardExcludeSystem.value,
      excludeAutomation: boardExcludeAutomation.value,
      author: boardAuthorFilter.value || undefined,
      hearth: boardHearthFilter.value || undefined,
      limit,
      offset: 0,
    }))
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

export function hydrateBoardSnapshot(data: DashboardMemoryResponse): void {
  const next = data.posts ?? []
  boardPosts.value = reconcileBoardPosts(boardPosts.value, next)
  const offset = typeof data.offset === 'number' ? data.offset : 0
  const limit = typeof data.limit === 'number' ? data.limit : boardPageSize()
  boardOffset.value = offset + next.length
  boardHasMore.value = typeof data.has_more === 'boolean'
    ? data.has_more
    : next.length >= limit
  boardTotal.value = typeof data.total === 'number' ? data.total : null
  lastBoardRefreshAt.value = data.generated_at ?? new Date().toISOString()
}

/** Append the next page of board posts onto boardPosts. Noop if a request is
 *  already in flight or the server indicated no more pages. */
export async function loadMoreBoardPosts(): Promise<void> {
  if (boardLoadingMore.value || boardLoading.value) return
  if (!boardHasMore.value) return
  boardLoadingMore.value = true
  try {
    const { fetchDashboardMemory } = await import('./api/dashboard-execution')
    const limit = boardPageSize()
    const offset = boardOffset.value
    const data = await timeBoardRequest('list_more', () => fetchDashboardMemory(boardSortMode.value, {
      excludeSystem: boardExcludeSystem.value,
      excludeAutomation: boardExcludeAutomation.value,
      author: boardAuthorFilter.value || undefined,
      hearth: boardHearthFilter.value || undefined,
      limit,
      offset,
    }))
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
  goalTreeLoading.value = true
  goalTreeError.value = null
  try {
    const [
      { fetchDashboardPlanning },
      { fetchDashboardGoalsTree },
    ] = await Promise.all([
      import('./api/dashboard-mission'),
      import('./api/dashboard-goals'),
    ])
    const [planning, tree] = await Promise.allSettled([
      fetchDashboardPlanning(),
      fetchDashboardGoalsTree(),
    ])
    const errors: string[] = []
    let generatedAt: string | undefined
    if (planning.status === 'fulfilled') {
      hydratePlanningSnapshot(planning.value, { markRefreshAt: false })
      generatedAt = planning.value.generated_at
    } else {
      console.warn('[Planning] fetch error:', planning.reason)
      errors.push(errorMessageOr(planning.reason, 'Planning data failed to load'))
    }
    if (tree.status === 'fulfilled') {
      const hydrated = hydrateGoalTreeSnapshot(tree.value)
      if (hydrated) {
        generatedAt ??= tree.value.generated_at
      } else {
        const message = 'Goal Store tree payload was malformed'
        hydrateGoalTreeObservationError(new Error(message))
        errors.push(goalTreeError.value ?? message)
      }
    } else {
      console.warn('[Goals] tree fetch error:', tree.reason)
      if (!hydrateGoalTreeError(tree.reason)) {
        hydrateGoalTreeObservationError(tree.reason)
      }
      const message = goalTreeError.value
        ?? errorMessageOr(tree.reason, 'Goal Store tree failed to load')
      errors.push(message)
    }
    if (errors.length > 0) {
      // Any failure invalidates the combined goal/tree snapshot so consumers
      // do not act on stale or partially-hydrated data.
      goalTreeData.value = null
      lastGoalsRefreshAt.value = null
      goalTreeError.value = errors.join('; ')
      showToast(WORK_GOAL_LOAD_PARTIAL_ERROR, 'error', WORK_GOAL_TOAST_DURATION_MS)
    } else {
      lastGoalsRefreshAt.value = generatedAt ?? new Date().toISOString()
    }
  } catch (err) {
    console.warn('[Planning] fetch error:', err)
    hydrateGoalTreeObservationError(err)
    lastGoalsRefreshAt.value = null
    showToast(WORK_GOAL_LOAD_ERROR, 'error', WORK_GOAL_TOAST_DURATION_MS)
  } finally {
    goalsLoading.value = false
    goalTreeLoading.value = false
  }
}

// --- Fusion board-sink + run registry fetchers (RFC-0266 §7 Phase 4) ---

// Fusion board posts are automation/sink evidence and must not inherit the
// operator's current Board filters. A Board route set to "hide system" would
// otherwise make Fusion claim no board-sink posts while live fusion evidence is
// present in the unfiltered board feed.
export async function refreshFusionBoard(): Promise<void> {
  fusionBoardLoading.value = true
  fusionBoardError.value = null
  try {
    const { fetchDashboardMemory } = await import('./api/dashboard-execution')
    const data = await timeBoardRequest('fusion_list', () => fetchDashboardMemory('recent', {
      limit: 500,
      offset: 0,
    }))
    fusionBoardPosts.value = reconcileBoardPosts(fusionBoardPosts.value, data.posts ?? [])
  } catch (err) {
    console.warn('[Fusion] board fetch error:', err)
    fusionBoardError.value = errorMessageOr(err, 'Fusion board-sink load failed')
  } finally {
    fusionBoardLoading.value = false
  }
}

// Re-fetched on route visit (tab-refresh) and on each `fusion_run_status` SSE
// event. The endpoint is the SSOT for run status; the dashboard never
// reconstructs registry state from the event payload, so a dropped/duplicated
// event self-heals on the next fetch.
export async function refreshFusionRuns(): Promise<void> {
  fusionRunsLoading.value = true
  fusionRunsError.value = null
  try {
    const { fetchFusionRuns } = await import('./api/dashboard-fusion')
    const data = await fetchFusionRuns()
    fusionRuns.value = data.runs
  } catch (err) {
    console.warn('[Fusion] runs fetch error:', err)
    fusionRunsError.value = errorMessageOr(err, 'Fusion run registry load failed')
  } finally {
    fusionRunsLoading.value = false
  }
}

export * from './store-normalizers'
