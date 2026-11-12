import { readCandleRosterObservation, type CandleReading } from './lib/candle-observation'
import { acceptedExecutionWorkspace, executionWorkspaceAuthority } from './execution-workspace-authority'
export { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from './execution-workspace-authority'
import { isObserverInstance } from './lib/observer-protocol'
import { decodeGoalProof } from './api/goal-proof'
import { decodeGoalResumePhase } from './api/goal-lifecycle'
import { fetchKeeperDeletions, type KeeperDeletionInventory } from './api/keeper-lifecycle'
// MASC Dashboard — Centralized reactive state via @preact/signals
// SSE events and API responses update these signals;
// subscribing components re-render automatically.

import { signal, computed, batch, type ReadonlySignal } from '@preact/signals'
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
import { showToast } from './components/common/toast'
import { errorMessageOr } from './lib/format-string'
import { observeGoalIds, type GoalIdentityObservation } from './lib/goal-identity'
import type { FusionRunEvidence } from './api/board'
import { isAbortError } from './lib/async-state'
import { normalizeKeepers } from './keeper-store-normalize'
import { setArrayByKeyIfChanged } from './signal-utils'
import { FetchScheduler } from './lib/fetch-scheduler'
import { createReadRecovery } from './lib/read-recovery'
import { ObservationPending, retainObservationReadFailure, setupObservationRefresh } from './lib/observation-refresh'
import { isRecord, asString, asNumber } from './components/common/normalize'
import { currentCanonicalDashboardActor, managedCredentialNeedsRevalidation, managedDashboardRefusal, setCanonicalDashboardActor } from './lib/dashboard-session-actor'
import { sanitizeDashboardActorName } from './lib/dashboard-actor'
import {
  captureDashboardObservationOwner,
  dashboardObservationOwnerIsCurrent,
  subscribeDashboardObservationOwnerChanges,
} from './lib/observation-read-owner'
import {
  captureDashboardCredentialOwner,
  ApiRequestError,
  dashboardCredentialOwnerIsCurrent,
  getStoredTokenMeta,
  type DashboardCredentialOwner,
} from './api/core'
import { recoverFromRejectedCredential } from './api/dev-token'
import { timeBoardRequest } from './board-metrics'
import { namespaceTruth, namespaceTruthError, namespaceTruthInitializing, namespaceTruthReadRecovery } from './namespace-truth-signals'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'
import {
  goalTreeData,
  advanceGoalTreeObservation,
  goalTreeError,
  goalTreeLoading,
  hydrateGoalSourceUnavailable,
  hydrateGoalTreeError,
  hydrateGoalTreeObservationError,
  hydrateGoalTreeSnapshot,
} from './goal-tree-state'
import { goalSourceUnavailable } from './api/dashboard-goals'
import type { GoalSourceUnavailable } from './types'
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
export const candleObservation = signal<CandleReading>({ status: 'unavailable', reason: 'Not yet read' })

// Acceptance is optimistic; completion comes only from durable shutdown receipts.
export const keeperPurgePending = signal<ReadonlySet<string>>(new Set<string>())
export const keeperDeletionInventory = signal<KeeperDeletionInventory | null>(null)
export const keeperDeletionError = signal<string | null>(null)
let keeperDeletionGeneration = 0

export function markKeeperPurgePending(name: string): void {
  const trimmed = name.trim()
  if (!trimmed || keeperPurgePending.value.has(trimmed)) return
  ++keeperDeletionGeneration
  keeperPurgePending.value = new Set([...keeperPurgePending.value, trimmed])
}

export async function refreshKeeperDeletions(): Promise<void> {
  const generation = ++keeperDeletionGeneration
  try {
    const inventory = await fetchKeeperDeletions()
    if (generation !== keeperDeletionGeneration) return
    batch(() => {
      keeperDeletionInventory.value = inventory
      keeperDeletionError.value = null
      const unresolved = inventory.operations.filter(row => !row.completed && row.phase !== 'superseded')
      const settled = new Set(inventory.operations
        .filter(row => row.completed || row.phase === 'superseded').map(row => row.keeperName))
      keeperPurgePending.value = new Set([
        ...[...keeperPurgePending.value].filter(name => !settled.has(name)),
        ...unresolved.map(row => row.keeperName), ...inventory.errors.map(row => row.keeperName),
      ])
    })
  } catch (error) {
    if (generation === keeperDeletionGeneration) {
      keeperDeletionError.value = error instanceof Error ? error.message : '삭제 기록 조회 실패'
    }
  }
}
export const serverStatus = signal<ServerStatus | null>(null)
// Authoritative backlog size from the execution payload's `task_counts.total`.
// The `tasks` signal holds only what the payload chose to send — active rows
// plus a bounded window of recent terminal ones — so counting it understates a
// tile labelled 전체 작업, most visibly for cancellations, which leave the
// window and then appear nowhere. Null when the payload omits the count.
export const executionTaskTotal = signal<number | null>(null)
// Invalidates asynchronous account reads when workspace/publication authority changes.
export const executionWorkspaceRevision = signal(0)
// Accepted roster observations drive retries without changing workspace identity.
export const keeperRosterObservationRevision = signal(0)
export const executionLoaded = signal(false)
export const executionLoading = signal(false)
export const executionError = signal<string | null>(null)
export const executionWorkerSupportBriefs = signal<DashboardExecutionWorkerSupportBrief[]>([])
export const executionContinuityBriefs = signal<DashboardExecutionContinuityBrief[]>([])

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
export const goalIdentityObservation = signal<{ readonly goals: Goal[]; readonly observation: GoalIdentityObservation } | null>(null)
export const goalsLoading = signal(false)

// --- Fusion run registry state (RFC-0266 §7 Phase 4) ---

import type { FusionRunRecord, DashboardFusionRunsResponse } from './api/dashboard-fusion'

// In-progress + recently completed fusion deliberations from the in-memory
// registry endpoint. Distinct from `boardPosts` (the board-derived detail the
// FusionSurface already renders): the registry is the only source that shows a
// run while it is still `running`, before any board post exists.
export const fusionBoardPosts = signal<BoardPost[]>([])
export const fusionBoardLoading = signal(false)
export const fusionBoardError = signal<string | null>(null)
export const fusionRuns = signal<FusionRunRecord[]>([])
export const fusionRunObservation = signal<Pick<DashboardFusionRunsResponse, 'replay' | 'historicalEvidence'> | null>(null)
export const fusionRunsLoading = signal(false)
export const fusionRunsError = signal<string | null>(null)

// --- Agent Core monitoring state ---

import type { AgentCoreAgentEvent, AgentCoreHealthSummary } from './types/agent-core'

import {
  AGENT_CORE_AGENT_EVENT_BUFFER,
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

// --- Refresh orchestration ---

// RefreshOptions imported from types/core.ts (SSOT)

// TTL values from config/constants.ts

let inflightDashboardRefresh: Promise<void> | null = null
export type ShellReadOutcome =
  | { readonly kind: 'ready' }
  | { readonly kind: 'failed'; readonly cause: unknown }
  | { readonly kind: 'cancelled' }
interface ShellRefreshFlight {
  readonly light: boolean
  readonly controller: AbortController
  promise: Promise<ShellReadOutcome>
  waiters: number
  settled: boolean
  stopAuthorityWatch: () => void
}
let inflightShellRefresh: ShellRefreshFlight | null = null
let shellRootCompletionRevision = 0
const shellReadRecovery = createReadRecovery()
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

// RFC-0444 §2.3 row 4: a Goal slice may be the typed store failure envelope
// (HTTP 200, no `error` line), which the slice-error guard above cannot see.
function firstGoalSourceUnavailable(slices: readonly unknown[]): GoalSourceUnavailable | null {
  for (const slice of slices) {
    const unavailable = goalSourceUnavailable(slice)
    if (unavailable !== null) return unavailable
  }
  return null
}

async function refreshDashboardFallback(opts?: RefreshOptions): Promise<void> {
  await Promise.all([refreshShell(opts), refreshExecution(opts)])
}

let goalObservationOwner = Symbol('initial Goal observation')
let pendingGoalRefresh: symbol | null = null

function hydrateDashboardBootstrap(
  data: DashboardBootstrapResponse,
  executionRequestGeneration: number,
  goalOwnerAtStart: symbol,
  authOwner: DashboardCredentialOwner,
  shellRootRevision: number,
  namespaceRevision: number,
): void {
  if (executionRequestGeneration !== executionSnapshotRequestGeneration()
    || !dashboardCredentialOwnerIsCurrent(authOwner)) return
  if (!data.shell || bootstrapSliceError(data.shell)) {
    throw new Error('dashboard bootstrap shell slice unavailable')
  }
  if (!data.execution || bootstrapSliceError(data.execution)) {
    throw new Error('dashboard bootstrap execution slice unavailable')
  }

  hydrateShellSnapshot(data.shell, { light: true, sentToken: authOwner.token, authOwner, rootRevision: shellRootRevision })
  hydrateExecutionSnapshot(data.execution, { requestGeneration: executionRequestGeneration, rootRevision: shellRootRevision })

  if (data.namespace_truth && !bootstrapSliceError(data.namespace_truth)
    && namespaceTruthReadRecovery.revision === namespaceRevision
    && !namespaceTruthReadRecovery.isReading) {
    const normalized = normalizeNamespaceTruth(data.namespace_truth)
    namespaceTruth.value = normalized
    namespaceTruthError.value = null
    namespaceTruthInitializing.value = false
    namespaceTruthReadRecovery.succeeded()
    hydrateShellRootSnapshot(normalized.root, true)
  }
  // A bootstrap may omit Goal slices. Such a response must not take ownership
  // away from an explicit refresh already loading the combined Goal snapshot.
  const hasGoalObservation = data.goals != null || bootstrapSliceError(data.planning)
    || (data.planning != null && pendingGoalRefresh === null)
  if (!hasGoalObservation || goalObservationOwner !== goalOwnerAtStart) return
  const owner = Symbol('bootstrap Goal observation')
  goalObservationOwner = owner
  pendingGoalRefresh = null
  try {
    const sourceUnavailable = firstGoalSourceUnavailable([data.planning, data.goals])
    if (sourceUnavailable === null) {
      if (data.planning && !bootstrapSliceError(data.planning)) {
        hydratePlanningSnapshot(data.planning)
      }
      if (data.goals && !bootstrapSliceError(data.goals)) {
        if (!hydrateGoalTreeSnapshot(data.goals)) {
          hydrateGoalTreeObservationError(new Error('Goal Store tree payload was malformed'))
        }
      }
    }
    const goalSourceErrors = [data.planning, data.goals]
      .filter(bootstrapSliceError).map(slice => slice.error)
    if (goalSourceErrors.length > 0) {
      goals.value = []
      lastGoalsRefreshAt.value = null
      hydrateGoalTreeObservationError(goalSourceErrors.join('; '))
    }
    if (sourceUnavailable !== null) {
      // The typed failure is the observation; a zero-goal planning snapshot
      // must not survive beside it.
      goals.value = []
      lastGoalsRefreshAt.value = null
      hydrateGoalSourceUnavailable(sourceUnavailable)
    }
  } catch (error) {
    if (goalObservationOwner === owner) {
      goals.value = []
      lastGoalsRefreshAt.value = null
      hydrateGoalTreeObservationError(error)
    }
  } finally {
    if (goalObservationOwner === owner) {
      goalsLoading.value = false
      goalTreeLoading.value = false
    }
  }
}

export async function refreshDashboard(opts?: RefreshOptions): Promise<void> {
  if (inflightDashboardRefresh) return inflightDashboardRefresh
  dashboardLoading.value = true
  inflightDashboardRefresh = (async () => {
    const executionRequestGeneration = executionSnapshotRequestGeneration()
    const goalOwnerAtStart = goalObservationOwner
    const authOwner = captureDashboardCredentialOwner()
    const workspaceOwner = executionWorkspaceAuthority.peek()
    const current = () => executionRequestGeneration === executionSnapshotRequestGeneration()
      && dashboardCredentialOwnerIsCurrent(authOwner) && executionWorkspaceAuthority.peek() === workspaceOwner
    try {
      executionLoading.value = true
      executionError.value = null
      try {
        const shellRootRevision = shellRootCompletionRevision
        const namespaceRevision = namespaceTruthReadRecovery.revision
        const data = await fetchDashboardBootstrap()
        if (!current()) return
        hydrateDashboardBootstrap(
          data,
          executionRequestGeneration,
          goalOwnerAtStart,
          authOwner,
          shellRootRevision,
          namespaceRevision,
        )
      } catch (bootstrapErr) {
        if (!current()) return
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
  const observedGoals = (Array.isArray(data.goals) ? data.goals : [])
    .map((row): Goal | null => {
      if (!isRecord(row)) return null
      // Preserve the stored Goal identity; action surfaces validate it.
      const id = typeof row.id === 'string' ? row.id : undefined
      const title = asString(row.title)
      const phase = asString(row.phase)
      const createdAt = asString(row.created_at)
      const updatedAt = asString(row.updated_at)
      if (!id || !title || !phase || !createdAt || !updatedAt) return null
      return {
        verification: decodeGoalProof(row.verification, id),
        resume_phase: decodeGoalResumePhase(phase, row.resume_phase),
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
  const observedIds = observeGoalIds(data.goals)
  const rollup = data.rollup
  const countFields = ['active_count', 'verifying_count', 'awaiting_confirmation_count',
    'done_count', 'dropped_count', 'paused_count', 'blocked_count'] as const
  const counts = isRecord(rollup) ? countFields.map(field => rollup[field]) : []
  const completeCounts = counts.length === countFields.length
    && counts.every((count): count is number => typeof count === 'number' && Number.isSafeInteger(count) && count >= 0)
  const observation = { ...observedIds, complete: observedIds.complete && completeCounts
    && (counts as number[]).reduce((total, count) => total + count, 0) === observedIds.ids.length }
  batch(() => {
    goals.value = observedGoals
    goalIdentityObservation.value = { goals: observedGoals, observation }
  })
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

   `recoverFromRejectedCredential` owns the whole policy, the same one a 401
   reply triggers: it re-mints a loopback dev token, drops any other token the
   server called invalid or expired, and does nothing once the stored token is
   no longer the one this shell request sent. `sentToken` is read before the
   request leaves for that comparison. */
function recoverFromRejectedShellAuth(
  auth: DashboardShellAuthSummary | null,
  sentToken: string | null,
): void {
  if (auth === null || auth.token_valid || !auth.token_present || sentToken === null) return
  void recoverFromRejectedCredential({ token: sentToken, authErrorCode: auth.auth_error_code ?? undefined })
    .catch(err => {
      console.warn('[dashboard-auth] rejected shell credential recovery failed', err)
    })
}

type ShellRootSnapshot = Pick<DashboardShellResponse, 'generated_at' | 'counts' | 'configured_keepers'>
  & { status?: ServerStatus | null }

/** Shell and namespace snapshots share this root projection. A namespace read
 * or push completion fences reads already in flight without claiming their auth or
 * config/runtime-resolution slices were refreshed. */
export function hydrateShellRootSnapshot(data: ShellRootSnapshot, completion = false): void {
  if (completion) shellRootCompletionRevision += 1
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  if (normalizedStatus) serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  if (data.counts) {
    const agents = asNumber(data.counts.agents)
    const keepers = asNumber(data.counts.keepers)
    const tasks = asNumber(data.counts.tasks)
    const totalRuntimes = asNumber(data.counts.total_runtimes)
      ?? (agents != null && keepers != null ? agents + keepers : undefined)
    const configuredKeepers = asNumber(data.configured_keepers)
    shellCounts.value = {
      ...(agents != null ? { agents } : {}),
      ...(tasks != null ? { tasks } : {}),
      ...(keepers != null ? { keepers } : {}),
      ...(totalRuntimes != null ? { total_runtimes: totalRuntimes } : {}),
      ...(configuredKeepers != null ? { configured_keepers: configuredKeepers } : {}),
    }
  }
}

export function hydrateShellSnapshot(
  data: DashboardShellResponse,
  opts: { light?: boolean; preserveAuth?: boolean; sentToken: string | null; authOwner?: DashboardCredentialOwner; recoverAuth?: boolean; rootRevision?: number },
): boolean {
  const wantsLight = opts.light === true
  const staleOwner = opts.authOwner !== undefined && !dashboardCredentialOwnerIsCurrent(opts.authOwner)
  if (staleOwner) return false
  const rootSuperseded = opts.rootRevision !== undefined && opts.rootRevision !== shellRootCompletionRevision
  const status: unknown = data.status
  const initializing = status === 'initializing' || (isRecord(status) && status.project === 'initializing')
  if (rootSuperseded && initializing) {
    // This read missed a completion we already accepted. Its synthetic auth
    // and empty projections cannot replace it, and no second producer event
    // is owed. Recover that one read after its current flight releases.
    const revision = shellReadRecovery.revision
    shellReadRecovery.waiting(() => { void refreshShell({ light: wantsLight, force: true }) })
    queueMicrotask(() => { if (shellReadRecovery.revision === revision) shellReadRecovery.recover() })
    return false
  }
  const preserveAuth = opts.preserveAuth === true
  let applyAuth = !preserveAuth
  const normalizedAuth = normalizeShellAuthSummary(data.auth)
  if (applyAuth) {
    const before = captureDashboardCredentialOwner()
    const previousActor = currentCanonicalDashboardActor()
    const nextActor = sanitizeDashboardActorName(normalizedAuth?.token_valid
      ? normalizedAuth.effective_agent ?? normalizedAuth.token_agent : null)
    const managedAuth = before.token !== null && getStoredTokenMeta()?.source === 'dev' && normalizedAuth?.token_present
      ? { tokenRevision: before.tokenRevision, rejected: !normalizedAuth.token_valid,
        verifiedAfterRefusal: normalizedAuth.token_valid && nextActor === 'dashboard'
          && opts.authOwner !== undefined && opts.sentToken === before.token } : undefined
    const alreadyRefused = managedDashboardRefusal.peek() === before.tokenRevision
    const authChanges = managedAuth && ((managedAuth.rejected && !alreadyRefused)
      || (managedAuth.verifiedAfterRefusal && managedCredentialNeedsRevalidation(before.tokenRevision))) ? 1 : 0
    const actorChanges = previousActor === nextActor ? 0 : 1
    const sameManagedHydration = previousActor === null && nextActor === 'dashboard'
    const managedActorChanges = (actorChanges === 1 && !sameManagedHydration) || authChanges === 1 ? 1 : 0
    setCanonicalDashboardActor(nextActor, managedAuth)
    const after = captureDashboardCredentialOwner()
    // The actor reset above belongs to this response. A separate token or
    // actor change triggered by a subscriber must not inherit its refusal.
    applyAuth = after.token === before.token && after.tokenRevision === before.tokenRevision
      && after.managed === before.managed
      && (before.managed
        ? after.managedActorRevision === before.managedActorRevision + managedActorChanges
        : after.actorRevision === before.actorRevision + actorChanges)
      && (!before.managed || (after.managedAuthRevision === before.managedAuthRevision + authChanges
        && after.managedRefusalObservation === before.managedRefusalObservation + (managedAuth?.rejected ? 1 : 0)))
      && currentCanonicalDashboardActor() === nextActor
    if (applyAuth && opts.recoverAuth !== false) recoverFromRejectedShellAuth(normalizedAuth, opts.sentToken)
  }
  if (opts.rootRevision === undefined || opts.rootRevision === shellRootCompletionRevision) {
    hydrateShellRootSnapshot(data)
  }
  if (applyAuth) {
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
  const admitted = !staleOwner && (opts.preserveAuth === true || applyAuth)
  lastShellRefreshAt = admitted ? Date.now() : 0
  if (admitted) {
    if (initializing) {
      shellReadRecovery.waiting(() => { void refreshShell({ light: wantsLight, force: true }) })
    } else shellReadRecovery.succeeded()
  }
  return admitted
}

function retireShellRefresh(flight: ShellRefreshFlight): void {
  flight.stopAuthorityWatch()
  flight.controller.abort()
  if (inflightShellRefresh === flight) {
    inflightShellRefresh = null
    lastShellRefreshAt = 0
  }
}

/** A caller can leave a shared read without cancelling its other consumers. */
function joinShellRefresh(flight: ShellRefreshFlight, signal?: AbortSignal): Promise<ShellReadOutcome> {
  if (signal?.aborted || flight.controller.signal.aborted) {
    if (!flight.settled && flight.waiters === 0) retireShellRefresh(flight)
    return Promise.resolve({ kind: 'cancelled' })
  }
  flight.waiters += 1
  return new Promise(resolve => {
    let finished = false
    const finish = (result: ShellReadOutcome) => {
      if (finished) return
      finished = true
      signal?.removeEventListener('abort', abort)
      flight.controller.signal.removeEventListener('abort', abort)
      flight.waiters -= 1
      if (!flight.settled && flight.waiters === 0) retireShellRefresh(flight)
      resolve(result)
    }
    const abort = () => finish({ kind: 'cancelled' })
    signal?.addEventListener('abort', abort, { once: true })
    flight.controller.signal.addEventListener('abort', abort, { once: true })
    void flight.promise.then(finish)
  })
}

/** Mounted shell observers keep the exact outcome of their shared request. */
export async function readShell(opts?: RefreshOptions & { recoverAuth?: boolean; signal?: AbortSignal }): Promise<ShellReadOutcome> {
  if (opts?.signal?.aborted) return { kind: 'cancelled' }
  const wantsLight = opts?.light === true
  if (inflightShellRefresh) {
    // A forced refresh must observe state established by the caller before
    // this invocation (notably Settings clearing the browser token). Joining
    // an older request could otherwise hydrate auth from the pre-clear token
    // and falsely report that the cleared state was rechecked.
    if (!opts?.force && (wantsLight || !inflightShellRefresh.light)) return joinShellRefresh(inflightShellRefresh, opts?.signal)
    await joinShellRefresh(inflightShellRefresh, opts?.signal)
    if (opts?.signal?.aborted) return { kind: 'cancelled' }
    // Another waiter may have started the required follow-up refresh while
    // this caller resumed. Join it only when it fetches at least as much as
    // this caller asked for. A light follow-up does not satisfy a full
    // request, so a full waiter that joined one would resolve without ever
    // fetching the full shell surface it asked for.
    if (inflightShellRefresh && (wantsLight || !inflightShellRefresh.light)) {
      return joinShellRefresh(inflightShellRefresh, opts?.signal)
    }
  }
  if (!opts?.force && Date.now() - lastShellRefreshAt < SHELL_TTL_MS) return { kind: 'ready' }
  const flight: ShellRefreshFlight = {
    light: wantsLight, controller: new AbortController(), promise: Promise.resolve({ kind: 'cancelled' }), waiters: 0, settled: false,
    stopAuthorityWatch: () => {},
  }
  inflightShellRefresh = flight
  shellReadRecovery.started()
  const authOwner = captureDashboardCredentialOwner()
  const requestOwner = captureDashboardObservationOwner()
  const rootRevision = shellRootCompletionRevision
  const stopAuthorityWatch = subscribeDashboardObservationOwnerChanges(() => retireShellRefresh(flight))
  flight.stopAuthorityWatch = stopAuthorityWatch
  const current = () => !flight.controller.signal.aborted
    && dashboardObservationOwnerIsCurrent(requestOwner)
  flight.promise = (async (): Promise<ShellReadOutcome> => {
    try {
      if (!current()) return { kind: 'cancelled' }
      const data = await fetchDashboardShell({ light: wantsLight, signal: flight.controller.signal })
      if (!current()) return { kind: 'cancelled' }
      // Hydration may itself update the canonical actor. That response-owned
      // transition is checked by hydrateShellSnapshot's credential CAS.
      stopAuthorityWatch()
      const admitted = hydrateShellSnapshot(data, { light: wantsLight, sentToken: authOwner.token, authOwner,
        recoverAuth: opts?.recoverAuth, rootRevision })
      return { kind: admitted ? 'ready' : 'cancelled' }
    } catch (err) {
      if (!current() || isAbortError(err)) return { kind: 'cancelled' }
      stopAuthorityWatch()
      // A failed read does not attest a different actor. Its own managed401
      // may retire strict hydration authority while the request headers stay
      // the same; keep that original refusal and its retry policy intact.
      shellAuthSummary.value = null
      shellReadRecovery.failed(() => { void refreshShell({ light: wantsLight, force: true }) },
        !(err instanceof ApiRequestError && (err.status === 401 || err.status === 403)))
      showToast('서버 연결 실패 — 데이터를 불러올 수 없습니다', 'error', 6000)
      console.warn('[Dashboard] shell fetch error:', err)
      return { kind: 'failed', cause: err }
    } finally {
      stopAuthorityWatch()
      flight.settled = true
      if (inflightShellRefresh === flight) inflightShellRefresh = null
    }
  })()
  return joinShellRefresh(flight, opts?.signal)
}

export async function refreshShell(opts?: RefreshOptions & { recoverAuth?: boolean; signal?: AbortSignal }): Promise<boolean> {
  const outcome = await readShell(opts)
  return outcome.kind === 'ready'
}

/** App owns initial boot separately; successful quiet observation does no HTTP. */
export function setupShellObservation(): () => void {
  return setupObservationRefresh(async signal => {
    const outcome = await readShell({ force: true, signal })
    if (outcome.kind === 'failed') throw retainObservationReadFailure(outcome.cause)
    if (outcome.kind === 'cancelled') throw new ObservationPending('Shell observation is pending')
  }, {
    topics: ['runtime_resolved'], initial: false,
  })
}

let executionPublicationEpoch: string | null = null
let executionReconnectPreviousEpoch: string | null = null
let executionReconnectAwaitingHttp = false
const executionReconnectInvalidationFloors = new Map<string, number>()
let executionPublicationGenerationWatermark = -1
let candleObservationSequenceWatermark = -1
let executionHydrationRequestGeneration = 0
const retiredExecutionPublicationEpochs = new Set<string>()

function withdrawExecutionWorkspaceAuthority(): void {
  acceptedExecutionWorkspace.value = null
  candleObservation.value = { status: 'unavailable', reason: 'Current workspace identity unavailable' }
}

function acceptExecutionWorkspace(
  epoch: string | null,
  workspaceRoot: unknown,
  observerInstance: unknown,
): void {
  if (epoch === null || typeof workspaceRoot !== 'string' || workspaceRoot.trim() === '') {
    withdrawExecutionWorkspaceAuthority()
    return
  }
  const previous = acceptedExecutionWorkspace.peek()
  const observerInstanceId = typeof observerInstance === 'string' && isObserverInstance(observerInstance)
    ? observerInstance : null
  if (
    previous?.epoch === epoch
    && previous.workspaceRoot === workspaceRoot
    && previous.connectionGeneration === executionHydrationRequestGeneration
    && previous.observerInstanceId === observerInstanceId
  ) return
  acceptedExecutionWorkspace.value = Object.freeze({
    epoch, workspaceRoot, connectionGeneration: executionHydrationRequestGeneration, observerInstanceId,
  })
}

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
    executionWorkspaceRevision.value += 1
    const previousEpoch = executionPublicationEpoch ?? executionReconnectPreviousEpoch
    if (previousEpoch !== null && previousEpoch !== epoch) {
      retireExecutionPublicationEpoch(previousEpoch)
    }
    executionPublicationEpoch = epoch
    candleObservationSequenceWatermark = -1
    withdrawExecutionWorkspaceAuthority()
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
  executionWorkspaceRevision.value += 1
  executionReconnectPreviousEpoch = executionPublicationEpoch
  executionPublicationEpoch = null
  executionPublicationGenerationWatermark = -1
  candleObservationSequenceWatermark = -1
  executionReconnectAwaitingHttp = true
  executionReconnectInvalidationFloors.clear()
  executionHydrationRequestGeneration += 1
  withdrawExecutionWorkspaceAuthority()
}

/** Hydrate all execution-related signals from a raw data payload.
 *  Shared by doFetchExecution (HTTP) and SSE execution_snapshot handler. */
export function hydrateExecutionSnapshot(
  data: DashboardExecutionResponse,
  opts?: { requestGeneration?: number; rootRevision?: number },
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
  const candleSequence = data.candle_observation_sequence
  if (candleSequence !== undefined && (!Number.isSafeInteger(candleSequence) || candleSequence < 0)) return false
  if (identity !== null && identity.epoch === executionPublicationEpoch
    && candleObservationSequenceWatermark >= 0
    && (candleSequence === undefined || candleSequence < candleObservationSequenceWatermark)) return false
  if (identity !== null) {
    if (executionPublicationEpoch === null) {
      executionWorkspaceRevision.value += 1
      candleObservationSequenceWatermark = -1
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
  if (candleSequence !== undefined) candleObservationSequenceWatermark = candleSequence
  const normalizedStatus = normalizeServerStatus(data.status, data.generated_at)
  // Read the current response only. mergeServerStatus may retain an old root
  // for presentation; that root cannot admit account reads in this response.
  acceptExecutionWorkspace(identity?.epoch ?? null, normalizedStatus?.workspace_root, data.observer_instance_id)
  const previousProject = serverStatus.value?.project
  const acceptsRoot = opts?.rootRevision === undefined || opts.rootRevision === shellRootCompletionRevision
  if (normalizedStatus && acceptsRoot) {
    serverStatus.value = mergeServerStatus(serverStatus.value, normalizedStatus)
  }
  const workspaceChanged =
    acceptsRoot && previousProject != null
    && normalizedStatus?.project != null
    && previousProject !== normalizedStatus.project
  if (workspaceChanged) {
    executionWorkspaceRevision.value += 1
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
  candleObservation.value = acceptedExecutionWorkspace.peek() === null
    ? { status: 'unavailable', reason: 'Current workspace identity unavailable' }
    : readCandleRosterObservation(data.candle, data.keepers)
  keepers.value = reconcileKeepers(keepers.value, normalizeKeepers(data.keepers))
  keeperRosterObservationRevision.value += 1
  const normalizedWorkerBriefs = (Array.isArray(data.worker_support_briefs) ? data.worker_support_briefs : Array.isArray(data.worker_briefs) ? data.worker_briefs : [])
    .map(normalizeExecutionWorkerSupportBrief)
    .filter((row): row is DashboardExecutionWorkerSupportBrief => row !== null)
  setArrayByKeyIfChanged(executionWorkerSupportBriefs, normalizedWorkerBriefs, w => w.name, stableValueEqual)
  const normalizedContinuityBriefs = (Array.isArray(data.continuity_briefs) ? data.continuity_briefs : [])
    .map(normalizeExecutionContinuityBrief)
    .filter((row): row is DashboardExecutionContinuityBrief => row !== null)
  setArrayByKeyIfChanged(executionContinuityBriefs, normalizedContinuityBriefs, c => c.name, stableValueEqual)
  executionLoaded.value = true
  executionReadRecovery.succeeded()
  return true
}

let nextExecutionForce = false

// A warm-up envelope carries no fleet. Hydrating it would reconcile the
// keeper list against [] and report the fleet as loaded-and-empty (the
// "일치하는 키퍼가 없습니다" screen 37s after a restart, 2026-08-22).
export function isInitializingExecutionPayload(data: DashboardExecutionResponse): boolean {
  const status: unknown = data.status
  return status === 'initializing' || (isRecord(status) && status.project === 'initializing')
}

const executionReadRecovery = createReadRecovery()

class ExecutionRefreshUnavailable extends ObservationPending {}

async function doFetchExecution(): Promise<void> {
  executionReadRecovery.started()
  const authOwner = captureDashboardCredentialOwner()
  const force = nextExecutionForce
  nextExecutionForce = false
  const requestGeneration = executionSnapshotRequestGeneration()
  const rootRevision = shellRootCompletionRevision
  const requestEpoch = executionPublicationEpoch
  const requestPublicationGeneration = executionPublicationGenerationWatermark
  const requestCandleSequence = candleObservationSequenceWatermark
  executionLoading.value = true
  executionError.value = null
  try {
    const { fetchDashboardExecution } = await import('./api/dashboard-execution')
    const data = await fetchDashboardExecution({ force })
    if (!dashboardCredentialOwnerIsCurrent(authOwner)) {
      throw new ExecutionRefreshUnavailable('Execution credential was superseded by a newer observation')
    }
    if (isInitializingExecutionPayload(data)) {
      if (requestGeneration !== executionHydrationRequestGeneration
        || requestEpoch !== executionPublicationEpoch
        || requestPublicationGeneration !== executionPublicationGenerationWatermark
      || requestCandleSequence !== candleObservationSequenceWatermark) {
        throw new ExecutionRefreshUnavailable('Execution initialization was superseded by a newer observation')
      }
      acceptedExecutionWorkspace.value = null
      candleObservation.value = { status: 'unavailable', reason: 'Server is initializing' }
      executionReadRecovery.waiting(() => { void executionScheduler.requestNow() })
      throw new ExecutionRefreshUnavailable('Execution projection is initializing')
    }
    if (!hydrateExecutionSnapshot(data, { requestGeneration, rootRevision })) {
      throw new ExecutionRefreshUnavailable('Execution response was superseded by a newer observation')
    }
  } catch (err) {
    // Initializing awaits its producer; superseded reads cannot
    // overwrite the newer accepted authority or turn into successful refresh.
    if (err instanceof ExecutionRefreshUnavailable) throw err
    if (requestGeneration !== executionHydrationRequestGeneration
      || requestEpoch !== executionPublicationEpoch
      || requestPublicationGeneration !== executionPublicationGenerationWatermark
      || requestCandleSequence !== candleObservationSequenceWatermark
      || !dashboardCredentialOwnerIsCurrent(authOwner)) {
      throw new ExecutionRefreshUnavailable('Execution failure was superseded by a newer observation')
    }
    console.warn('[Dashboard] execution fetch error:', err)
    acceptedExecutionWorkspace.value = null
    executionError.value = errorMessageOr(err, 'Execution projection load failed')
    candleObservation.value = { status: 'unavailable', reason: executionError.value }
    executionReadRecovery.failed(() => { void executionScheduler.requestNow() },
      !(err instanceof ApiRequestError && (err.status === 401 || err.status === 403)))
    showToast('실행 데이터 로드 실패', 'error', 5000)
    throw retainObservationReadFailure(err)
  } finally {
    executionLoading.value = false
  }
}

const executionScheduler = new FetchScheduler(doFetchExecution, {
  cooldownMs: 2_000,
  debounceMs: 300,
})

export function recoverExecutionReadDebt(authorityChanged = false): void {
  executionReadRecovery.recover(authorityChanged)
}

export function recoverShellReadDebt(authorityChanged = false): void {
  shellReadRecovery.recover(authorityChanged)
}

export function disposeExecutionReadRecovery(): void {
  executionReadRecovery.dispose()
  shellReadRecovery.dispose()
  if (inflightShellRefresh) retireShellRefresh(inflightShellRefresh)
  executionScheduler.dispose()
}

export function refreshExecution(opts?: RefreshOptions): Promise<void> {
  if (opts?.force) {
    nextExecutionForce = true
    return executionScheduler.requestNow()
  }
  if (opts?.immediate) return executionScheduler.requestNow()
  executionScheduler.request()
  // Preserve normal scheduling/current-wait semantics. Return the already
  // observed promise itself so ignored background refreshes remain handled.
  return executionScheduler.inflightPromise ?? Promise.resolve()
}

export async function refreshKeeperRuntimeStatus(opts?: RefreshOptions): Promise<void> {
  const force = opts?.force ?? true
  try {
    await refreshShell({ light: true, force })
    await refreshExecution({ force })
  } finally {
    // Deletion receipts are independent of execution projection availability.
    await refreshKeeperDeletions()
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
    && stableValueEqual(previous.audience, next.audience)
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
  const owner = Symbol('explicit Goal observation')
  goalObservationOwner = owner
  pendingGoalRefresh = owner
  goalsLoading.value = true
  goalTreeLoading.value = true
  // A retry is not a new observation. Keep the last source error until a
  // successful response replaces it, so an empty cache cannot look healthy.
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
    if (goalObservationOwner !== owner) return
    const errors: string[] = []
    let generatedAt: string | undefined
    // The tree is hydrated before Planning so a typed Planning failure
    // (GoalSourceUnavailableError) is the state left standing when both
    // arrive; a tree success would otherwise clear it.
    if (tree.status === 'fulfilled') {
      const hydrated = hydrateGoalTreeSnapshot(tree.value)
      if (hydrated) {
        generatedAt = tree.value.generated_at
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
    if (planning.status === 'fulfilled') {
      hydratePlanningSnapshot(planning.value, { markRefreshAt: false })
      generatedAt = planning.value.generated_at ?? generatedAt
    } else {
      console.warn('[Planning] fetch error:', planning.reason)
      if (hydrateGoalTreeError(planning.reason)) {
        errors.push(goalTreeError.value ?? errorMessageOr(planning.reason, 'Planning data failed to load'))
      } else {
        errors.push(errorMessageOr(planning.reason, 'Planning data failed to load'))
      }
    }
    if (errors.length > 0) {
      // Any failure invalidates the combined goal/tree snapshot so consumers
      // do not act on stale or partially-hydrated data.
      goals.value = []
      advanceGoalTreeObservation()
      goalTreeData.value = null
      lastGoalsRefreshAt.value = null
      goalTreeError.value = errors.join('; ')
      showToast(WORK_GOAL_LOAD_PARTIAL_ERROR, 'error', WORK_GOAL_TOAST_DURATION_MS)
    } else {
      lastGoalsRefreshAt.value = generatedAt ?? new Date().toISOString()
    }
  } catch (err) {
    if (goalObservationOwner !== owner) return
    goals.value = []
    console.warn('[Planning] fetch error:', err)
    hydrateGoalTreeObservationError(err)
    lastGoalsRefreshAt.value = null
    showToast(WORK_GOAL_LOAD_ERROR, 'error', WORK_GOAL_TOAST_DURATION_MS)
  } finally {
    if (goalObservationOwner === owner) {
      pendingGoalRefresh = null
      goalsLoading.value = false
      goalTreeLoading.value = false
    }
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
    // A run the window did not carry can be asked for again: it may have
    // written its post since, and a run that has one now is not the run that
    // had none when it was last asked.
    forgetFusionEvidenceRequests()
  } catch (err) {
    console.warn('[Fusion] board fetch error:', err)
    fusionBoardError.value = errorMessageOr(err, 'Fusion board-sink load failed')
  } finally {
    fusionBoardLoading.value = false
  }
}

// One run's board-sink evidence, fetched by the run's own id.
//
// refreshFusionBoard reads the last 500 board posts, so how long a run's panel
// and judge detail stays readable is decided by how busy the board is. On a
// 2,055-row board two runs from two days earlier sat 553rd and 1,231st from the
// end and their detail could not be opened at all (#33562).
//
// The server answers this from an exact run-id index, so it costs the same
// whatever the board has done since. Merged into the same signal the list fills:
// a run found either way is one run, and reconcileBoardPosts keeps the identity.
//
// Keep lookup state separate from registry lifecycle and cached Board rows.
// Settled failures remain visible and require deliberate retry, avoiding a
// render-driven retry loop while preserving the original request's ownership.
type FusionEvidenceRead = { request: symbol } & (
  | { status: 'loading' }
  | { status: 'failed'; error: string }
  | FusionRunEvidence
)
export const fusionEvidenceRequests = signal<ReadonlyMap<string, FusionEvidenceRead>>(new Map())

export async function loadFusionRunEvidence(runId: string, options: { retry?: boolean } = {}): Promise<void> {
  const requests = fusionEvidenceRequests.peek()
  const prior = requests.get(runId)
  if (runId === '' || (prior && (!options.retry || prior.status === 'loading'))) return
  const request = Symbol(runId)
  fusionEvidenceRequests.value = new Map(requests).set(runId, { request, status: 'loading' })
  try {
    const { fetchFusionRunEvidence } = await import('./api/board')
    const evidence = await fetchFusionRunEvidence(runId)
    // A list refresh retires previous requests. A late answer from that
    // earlier read must not replace evidence fetched after the refresh.
    if (fusionEvidenceRequests.peek().get(runId)?.request !== request) return
    batch(() => {
      fusionEvidenceRequests.value = new Map(fusionEvidenceRequests.peek()).set(runId, { request, ...evidence })
      if (evidence.status === 'recorded') {
        const post = evidence.post
        fusionBoardPosts.value = reconcileBoardPosts(fusionBoardPosts.value, [
          post,
          ...fusionBoardPosts.value.filter(existing => existing.id !== post.id),
        ])
      }
    })
  } catch (err) {
    if (fusionEvidenceRequests.peek().get(runId)?.request !== request) return
    fusionEvidenceRequests.value = new Map(fusionEvidenceRequests.peek()).set(runId, {
      request, status: 'failed', error: errorMessageOr(err, 'Fusion evidence read failed'),
    })
  }
}

// A run whose evidence was asked for once is not asked again, which is what
// keeps a render loop from making a request per frame. Cleared when the list
// itself is refetched, so a run that had no post yet can be asked again after
// its deliberation lands.
export function forgetFusionEvidenceRequests(): void {
  fusionEvidenceRequests.value = new Map()
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
    batch(() => {
      fusionRuns.value = data.runs
      fusionRunObservation.value = { replay: data.replay, historicalEvidence: data.historicalEvidence }
    })
  } catch (err) {
    console.warn('[Fusion] runs fetch error:', err)
    fusionRunsError.value = errorMessageOr(err, 'Fusion run registry load failed')
  } finally {
    fusionRunsLoading.value = false
  }
}

export * from './store-normalizers'
