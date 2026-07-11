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
  DashboardWorkspaceFsmEvidence,
  DashboardWorkspaceFsmProduct,
  DashboardWorkspaceFsmRefs,
  DashboardWorkspaceFsmSnapshot,
  DashboardWorkspaceFsmViolation,
} from './types'
import { fetchDashboardBootstrap, fetchDashboardShell } from './api/dashboard-hot'
import { journal } from './sse'
import { showToast } from './components/common/toast'
import { errorMessageOr } from './lib/format-string'
import {
  keeperFreshnessTs,
  normalizeKeepers,
} from './keeper-store-normalize'
import { buildAgentMotion, normalizeAgentKey, type AgentMotionSnapshot } from './components/common/agent-motion'
import {
  canonicalKeeperNameFromAgentName,
  keeperIdentityKeys,
  keeperPrincipalKey,
} from './components/common/keeper-identity'
import { groupByKey } from './components/common/collection'
import { setArrayByKeyIfChanged } from './signal-utils'
import { FetchScheduler } from './lib/fetch-scheduler'
import { isRecord, asString, asNumber, asStringArray } from './components/common/normalize'
import { setCanonicalDashboardActor } from './lib/dashboard-session-actor'
import { timeBoardRequest } from './board-metrics'
import { namespaceTruth, namespaceTruthError, namespaceTruthInitializing } from './namespace-truth-signals'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'
import { goalTreeData, goalTreeError, goalTreeLoading, hydrateGoalTreeSnapshot } from './goal-tree-state'
import { hydrateGoalLoopSnapshot } from './goal-loop-state'
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
  agents: number
  tasks: number
  keepers: number
  total_runtimes: number
  configured_keepers: number
}

export const shellCounts = signal<ShellCounts | null>(null)
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
export const executionWorkerSupportBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])
export const executionContinuityBriefs = signal<DashboardExecutionContinuityBrief[]>([])

// --- Keeper heartbeat tracking (name -> last heartbeat timestamp ms) ---

export const keeperHeartbeats = signal<Map<string, number>>(new Map())

// --- Cross-zone keeper filter (Phase 2 · I0-B) ---
// Empty set means "all keepers". Components that consume the filter
// should treat `size === 0` as the unconstrained case so the default
// route stays the broadest view. Adding a keeper id narrows the scope.
export const selectedKeeperFilter = signal<Set<string>>(new Set())

export function toggleKeeperInFilter(name: string): void {
  const next = new Set(selectedKeeperFilter.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  selectedKeeperFilter.value = next
}

// --- Optimistic keeper directive patching ---
//
// Server's `refresh_keeper_execution_surfaces` invalidates the
// projection cache prefix, so the next dashboard fetch recomputes
// from scratch (hundreds of ms+). The operator perceives this as
// "재개하기 누르면 느림" even though the directive POST itself
// returns in <50ms — the row keeps showing the old state until the
// projection refetch completes.
//
// To close the gap we mutate the local `keepers` signal immediately
// on click. The action button's `keeperActionVisibility` predicate
// flips, the phase badge updates, and the next reconciling snapshot
// from WS/SSE or `refreshDashboard` confirms (or corrects) the
// optimistic state. Restricted to pause/resume/wakeup — boot and
// shutdown have non-trivial lifecycle transitions that should wait
// on the authoritative server response.

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
    case 'wakeup':
      return { paused: false, phase: 'Running', lifecycle_phase: 'Running', pipeline_stage: 'idle', status: 'idle' }
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

export function clearKeeperFilter(): void {
  selectedKeeperFilter.value = new Set()
}

export function setKeeperFilterToAll(allNames: readonly string[]): void {
  selectedKeeperFilter.value = new Set(allNames)
}

const KEEPER_RELATIVE_AGE_FIELDS = new Set<string>([
  'keeper_age_s',
  'last_activity_ago_s',
  'last_turn_ago_s',
  'last_handoff_ago_s',
  'last_compaction_ago_s',
  'last_proactive_ago_s',
  'next_eligible_at_s',
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
export const workspaceFsmSnapshot = signal<DashboardWorkspaceFsmSnapshot | null>(null)

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
export const oasReplayLoadedEvents = signal(0)
export const oasReplayTotalMatchingEvents = signal(0)
export const oasReplayTruncated = signal(false)
export const oasTotalLlmCalls = signal(0)
export const oasTotalErrors = signal(0)
export const oasLastLlmCallTs = signal<number | null>(null)
export const oasLastErrorTs = signal<number | null>(null)
export const oasEvidenceRefsCount = signal(0)
export const oasArtifactRefsCount = signal(0)
export const oasRawTraceRefsCount = signal(0)
export const oasReportRefsCount = signal(0)
export const oasProofRefsCount = signal(0)
export const oasTelemetryRefsCount = signal(0)
export const oasRuntimeEvidenceRefsCount = signal(0)
export const oasLastEvidenceTs = signal<number | null>(null)

export function resetOasRuntimeSignals(): void {
  oasAgentEventsRing.clear()
  oasAgentEvents.value = []
  oasKeeperSnapshots.value = new Map()
  oasLastKeeperTick.value = null
  oasTotalEvents.value = 0
  oasReplayLoadedEvents.value = 0
  oasReplayTotalMatchingEvents.value = 0
  oasReplayTruncated.value = false
  oasTotalLlmCalls.value = 0
  oasTotalErrors.value = 0
  oasLastLlmCallTs.value = null
  oasLastErrorTs.value = null
  oasEvidenceRefsCount.value = 0
  oasArtifactRefsCount.value = 0
  oasRawTraceRefsCount.value = 0
  oasReportRefsCount.value = 0
  oasProofRefsCount.value = 0
  oasTelemetryRefsCount.value = 0
  oasRuntimeEvidenceRefsCount.value = 0
  oasLastEvidenceTs.value = null
}

export function noteOasReplayWindow(input: {
  loadedEvents: number
  totalMatchingEvents: number
  truncated: boolean
}): void {
  const loadedEvents = Math.max(0, Math.floor(input.loadedEvents))
  const totalMatchingEvents = Math.max(loadedEvents, Math.floor(input.totalMatchingEvents))
  const truncated = input.truncated && totalMatchingEvents > loadedEvents
  oasReplayLoadedEvents.value = loadedEvents
  oasReplayTotalMatchingEvents.value = totalMatchingEvents
  oasReplayTruncated.value = truncated
  oasTotalEvents.value = totalMatchingEvents
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

export function recordOasEvidenceRefs(input: {
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
  oasEvidenceRefsCount.value += evidenceRefsCount
  oasArtifactRefsCount.value += artifactRefsCount
  oasRawTraceRefsCount.value += rawTraceRefsCount
  oasReportRefsCount.value += reportRefsCount
  oasProofRefsCount.value += proofRefsCount
  oasTelemetryRefsCount.value += telemetryRefsCount
  oasRuntimeEvidenceRefsCount.value += runtimeEvidenceRefsCount
  if (typeof input.tsMs === 'number' && Number.isFinite(input.tsMs)) {
    oasLastEvidenceTs.value = Math.max(oasLastEvidenceTs.value ?? 0, input.tsMs)
  }
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
  replayLoadedEvents: oasReplayLoadedEvents.value,
  replayTotalMatchingEvents: oasReplayTotalMatchingEvents.value,
  replayTruncated: oasReplayTruncated.value,
  hasMore: oasReplayTruncated.value,
  totalLlmCalls: oasTotalLlmCalls.value,
  totalErrors: oasTotalErrors.value,
  lastLlmCallTs: oasLastLlmCallTs.value,
  lastErrorTs: oasLastErrorTs.value,
  evidenceRefsCount: oasEvidenceRefsCount.value,
  artifactRefsCount: oasArtifactRefsCount.value,
  rawTraceRefsCount: oasRawTraceRefsCount.value,
  reportRefsCount: oasReportRefsCount.value,
  proofRefsCount: oasProofRefsCount.value,
  telemetryRefsCount: oasTelemetryRefsCount.value,
  runtimeEvidenceRefsCount: oasRuntimeEvidenceRefsCount.value,
  lastEvidenceTs: oasLastEvidenceTs.value,
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
      keeperPrincipalKey(keeper.keeper_id, keeper.name, keeper.agent_name)
      ?? normalizeAgentKey(keeper.name)
    for (const key of keeperIdentityKeys(keeper.keeper_id, keeper.name, keeper.agent_name)) {
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
  const known = lookup.get(raw)
  if (known) return known
  const alias = canonicalKeeperNameFromAgentName(value)
  return alias ? `keeper:${alias.toLowerCase()}` : raw
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
    k => keeperPrincipalKey(k.keeper_id, k.name, k.agent_name) ?? normalizeAgentKey(k.name),
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
    if (lastTs != null && (now - lastTs) > HEARTBEAT_STALE_MS) {
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
let lastShellRefreshAt = 0

export function invalidateDashboardCache(): void {
  // Projection endpoints are intentionally fresh-first after the operator-console rewrite.
}

function bootstrapSliceError(slice: unknown): slice is DashboardBootstrapSliceError {
  return isRecord(slice) && typeof slice.error === 'string'
}

async function refreshDashboardFallback(opts?: RefreshOptions): Promise<void> {
  await Promise.all([refreshShell(opts), refreshExecution(opts)])
}

function hydrateDashboardBootstrap(data: DashboardBootstrapResponse): void {
  if (!data.shell || bootstrapSliceError(data.shell)) {
    throw new Error('dashboard bootstrap shell slice unavailable')
  }
  if (!data.execution || bootstrapSliceError(data.execution)) {
    throw new Error('dashboard bootstrap execution slice unavailable')
  }

  hydrateShellSnapshot(data.shell, { light: true })
  hydrateExecutionSnapshot(data.execution)

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
    hydrateGoalTreeSnapshot(data.goals)
  }
  if (data.goal_loop_status && !bootstrapSliceError(data.goal_loop_status)) {
    // RFC-0284: seed the goal-loop store on first page load so the panel
    // renders without its own fetch; live updates then arrive over SSE.
    hydrateGoalLoopSnapshot(data.goal_loop_status)
  }
}

export async function refreshDashboard(opts?: RefreshOptions): Promise<void> {
  if (inflightDashboardRefresh) return inflightDashboardRefresh
  dashboardLoading.value = true
  inflightDashboardRefresh = (async () => {
    try {
      executionLoading.value = true
      executionError.value = null
      try {
        hydrateDashboardBootstrap(await fetchDashboardBootstrap())
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

function normalizeWorkspaceFsmRefs(raw: unknown): DashboardWorkspaceFsmRefs {
  const refsRecord = isRecord(raw) ? raw : {}
  return {
    goal_id: asString(refsRecord.goal_id) ?? null,
    task_ids: asStringArray(refsRecord.task_ids),
    post_ids: asStringArray(refsRecord.post_ids),
    agent_name: asString(refsRecord.agent_name) ?? null,
  }
}

function normalizeWorkspaceFsmEvidence(raw: unknown): DashboardWorkspaceFsmEvidence | null {
  if (!isRecord(raw)) return null
  return {
    source: asString(raw.source) ?? undefined,
    kind: asString(raw.kind) ?? undefined,
    id: asString(raw.id) ?? null,
    label: asString(raw.label) ?? undefined,
    detail: asString(raw.detail) ?? undefined,
    timestamp: asNumber(raw.timestamp) ?? null,
    refs: normalizeWorkspaceFsmRefs(raw.refs),
  }
}

function normalizeWorkspaceFsmEvidenceList(raw: unknown): DashboardWorkspaceFsmEvidence[] {
  return Array.isArray(raw)
    ? raw
      .map(normalizeWorkspaceFsmEvidence)
      .filter((row): row is DashboardWorkspaceFsmEvidence => row !== null)
    : []
}

function refsOverlap(
  left: DashboardWorkspaceFsmRefs | undefined,
  right: DashboardWorkspaceFsmRefs | undefined,
): boolean {
  if (!left || !right) return false
  if (left.goal_id && left.goal_id === right.goal_id) return true
  if (left.agent_name && left.agent_name === right.agent_name) return true
  if ((left.task_ids ?? []).some(taskId => (right.task_ids ?? []).includes(taskId))) return true
  return (left.post_ids ?? []).some(postId => (right.post_ids ?? []).includes(postId))
}

function normalizeWorkspaceFsmSnapshot(raw: unknown): DashboardWorkspaceFsmSnapshot | null {
  if (!isRecord(raw)) return null
  const summaryRecord = isRecord(raw.summary) ? raw.summary : {}
  const severityRecord = isRecord(summaryRecord.severity_counts)
    ? summaryRecord.severity_counts
    : {}
  const products: DashboardWorkspaceFsmProduct[] = Array.isArray(raw.products)
    ? raw.products
      .map((row): DashboardWorkspaceFsmProduct | null => {
        if (!isRecord(row)) return null
        return {
          refs: normalizeWorkspaceFsmRefs(row.refs),
          goal: asString(row.goal) ?? null,
          task: asString(row.task) ?? undefined,
          board: asString(row.board) ?? undefined,
          reward: asString(row.reward) ?? undefined,
          evidence: normalizeWorkspaceFsmEvidenceList(row.evidence),
          violations: Array.isArray(row.violations)
            ? row.violations
              .map((violation): DashboardWorkspaceFsmViolation | null => {
                if (!isRecord(violation)) return null
                return {
                  axis: asString(violation.axis) ?? undefined,
                  code: asString(violation.code) ?? undefined,
                  severity: asString(violation.severity) ?? undefined,
                  message: asString(violation.message) ?? undefined,
                  refs: normalizeWorkspaceFsmRefs(violation.refs),
                  evidence: normalizeWorkspaceFsmEvidenceList(violation.evidence),
                }
              })
              .filter((violation): violation is DashboardWorkspaceFsmViolation => violation !== null)
            : [],
        }
      })
      .filter((row): row is DashboardWorkspaceFsmProduct => row !== null)
    : []
  const fallbackEvidence = products.flatMap(product => product.evidence ?? [])
  const snapshotEvidence = normalizeWorkspaceFsmEvidenceList(raw.evidence)
  const evidence = snapshotEvidence.length > 0 ? snapshotEvidence : fallbackEvidence
  const violations = Array.isArray(raw.violations)
    ? raw.violations
      .map((row): DashboardWorkspaceFsmViolation | null => {
        if (!isRecord(row)) return null
        const refs = normalizeWorkspaceFsmRefs(row.refs)
        const rowEvidence = normalizeWorkspaceFsmEvidenceList(row.evidence)
        return {
          axis: asString(row.axis) ?? undefined,
          code: asString(row.code) ?? undefined,
          severity: asString(row.severity) ?? undefined,
          message: asString(row.message) ?? undefined,
          refs,
          evidence: rowEvidence.length > 0
            ? rowEvidence
            : fallbackEvidence.filter(item => refsOverlap(refs, item.refs)).slice(0, 5),
        }
      })
      .filter((row): row is DashboardWorkspaceFsmViolation => row !== null)
    : []
  return {
    schema_version: asNumber(raw.schema_version) ?? undefined,
    mode: asString(raw.mode) ?? undefined,
    summary: {
      products: asNumber(summaryRecord.products) ?? undefined,
      violations: asNumber(summaryRecord.violations) ?? undefined,
      evidence: asNumber(summaryRecord.evidence) ?? evidence.length,
      severity_counts: {
        info: asNumber(severityRecord.info) ?? 0,
        warn: asNumber(severityRecord.warn) ?? 0,
        error: asNumber(severityRecord.error) ?? 0,
      },
    },
    products,
    evidence,
    violations,
    projection_error: asString(raw.projection_error) ?? null,
  }
}

function applyPlanningEnvelope(data: DashboardPlanningResponse): void {
  workspaceFsmSnapshot.value = normalizeWorkspaceFsmSnapshot(data.workspace_fsm)
  goals.value = (Array.isArray(data.goals) ? data.goals : [])
    .map((row): Goal | null => {
      if (!isRecord(row)) return null
      const id = asString(row.id)
      const title = asString(row.title)
      const status = asString(row.status)
      const phase = asString(row.phase)
      const createdAt = asString(row.created_at)
      const updatedAt = asString(row.updated_at)
      if (!id || !title || !status || !phase || !createdAt || !updatedAt) return null
      return {
        id,
        title,
        metric: asString(row.metric) ?? null,
        target_value: asString(row.target_value) ?? null,
        due_date: asString(row.due_date) ?? null,
        priority: asNumber(row.priority) ?? 3,
        status,
        phase,
        verifier_policy: (isRecord(row.verifier_policy) ? row.verifier_policy : null) as Goal['verifier_policy'],
        require_completion_approval: row.require_completion_approval === true,
        active_verification_request_id: asString(row.active_verification_request_id) ?? null,
        parent_goal_id: asString(row.parent_goal_id) ?? null,
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
    default_role: asString(raw.default_role) ?? null,
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

export function hydrateShellSnapshot(
  data: DashboardShellResponse,
  opts?: { light?: boolean; preserveAuth?: boolean },
): void {
  const wantsLight = opts?.light === true
  const preserveAuth = opts?.preserveAuth === true
  const normalizedAuth = normalizeShellAuthSummary(data.auth)
  if (!preserveAuth) {
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
    shellCounts.value = {
      agents: data.counts.agents ?? 0,
      tasks: data.counts.tasks ?? 0,
      keepers: data.counts.keepers ?? 0,
      total_runtimes: data.counts.total_runtimes ?? ((data.counts.agents ?? 0) + (data.counts.keepers ?? 0)),
      configured_keepers: data.configured_keepers ?? 0,
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

/** Hydrate all execution-related signals from a raw data payload.
 *  Shared by doFetchExecution (HTTP) and SSE execution_snapshot handler. */
export function hydrateExecutionSnapshot(data: DashboardExecutionResponse): void {
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  const previousProject = serverStatus.value?.project
  if (normalizedStatus) {
    serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  }
  const workspaceChanged =
    previousProject != null
    && normalizedStatus?.project != null
    && previousProject !== normalizedStatus.project
  const normalizedAgents = (Array.isArray(data.agents) ? data.agents : [])
    .map(normalizeAgent)
    .filter((row): row is Agent => row !== null)
  setArrayByKeyIfChanged(agents, normalizedAgents, a => a.name, stableValueEqual)
  const normalizedTasks = (Array.isArray(data.tasks) ? data.tasks : [])
    .map(normalizeTask)
    .filter((row): row is Task => row !== null)
  setArrayByKeyIfChanged(tasks, normalizedTasks, t => t.id, stableValueEqual)
  const executionMessages = (Array.isArray(data.messages) ? data.messages : [])
    .map(normalizeMessage)
    .filter((row): row is Message => row !== null)
  messages.value = workspaceChanged ? executionMessages : mergeMessages(messages.value, executionMessages)
  keepers.value = reconcileKeepers(keepers.value, normalizeKeepers(data.keepers))
  const normalizedWorkerBriefs = (Array.isArray(data.worker_support_briefs) ? data.worker_support_briefs : Array.isArray(data.worker_briefs) ? data.worker_briefs : [])
    .map(normalizeExecutionWorkerSupportBrief)
    .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
  setArrayByKeyIfChanged(executionWorkerSupportBriefs, normalizedWorkerBriefs, w => w.name, stableValueEqual)
  const normalizedContinuityBriefs = (Array.isArray(data.continuity_briefs) ? data.continuity_briefs : [])
    .map(normalizeExecutionContinuityBrief)
    .filter((row): row is DashboardExecutionContinuityBrief => row !== null)
  setArrayByKeyIfChanged(executionContinuityBriefs, normalizedContinuityBriefs, c => c.name, stableValueEqual)
  executionLoaded.value = true
}

let nextExecutionForce = false

async function doFetchExecution(): Promise<void> {
  const force = nextExecutionForce
  nextExecutionForce = false
  executionLoading.value = true
  executionError.value = null
  try {
    const { fetchDashboardExecution } = await import('./api/dashboard-execution')
    const data = await fetchDashboardExecution({ force })
    hydrateExecutionSnapshot(data)
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
    && (left?.runtime_agent_name ?? null) === (right?.runtime_agent_name ?? null)
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
    && previous.content === next.content
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
        goalTreeError.value = message
        errors.push(message)
      }
    } else {
      console.warn('[Goals] tree fetch error:', tree.reason)
      const message = errorMessageOr(tree.reason, 'Goal Store tree failed to load')
      goalTreeError.value = message
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
    const message = errorMessageOr(err, 'Goal refresh failed')
    goalTreeError.value = message
    goalTreeData.value = null
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
