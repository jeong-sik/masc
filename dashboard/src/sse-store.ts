// WebSocket server-push reaction and periodic refresh — extracted from store.ts
// Routes pushed events to the minimal refresh function needed.
//
// Event routing uses a declarative map for simple refresh-only events,
// and named handlers for events with custom logic (conditional hydration,
// async imports, signal-only updates).

import {
  pauseQueuedAgentCoreRuntimeIngress,
  resumeQueuedAgentCoreRuntimeIngress,
  normalizeSSEDispatchType,
} from './sse'
import {
  dashboardWsLastDisconnectedAt,
  dashboardWsReady,
  dashboardWsReconnectCount,
} from './dashboard-ws-state'
import type {
  BoardPost,
  DashboardExecutionResponse,
  KeeperApprovalAuditReceipt,
  SSEEvent,
} from './types'
import type * as TransportHealth from './components/transport-health'
import {
  keeperHeartbeats,
  invalidateDashboardCache,
  invalidateExecutionSnapshotGeneration,
  hydrateExecutionSnapshot,
  resetExecutionSnapshotGeneration,
  refreshDashboard,
  refreshExecution,
  refreshBoard,
  refreshFusionRuns,
  serverStatus,
  boardPosts,
  boardSortMode,
  boardExcludeSystem,
  boardExcludeAutomation,
  boardAuthorFilter,
  boardHearthFilter,
  boardOffset,
} from './store'
import {
  requestNamespaceTruth,
  requestNamespaceTruthNow,
  namespaceTruth,
  namespaceTruthError,
  normalizeNamespaceTruth,
} from './namespace-truth-store'
import { mergeServerStatus } from './store-normalizers'
import { normalizeOperatorSnapshot, normalizeOperatorDigest } from './operator-normalizers'
import { operatorError, operatorSnapshot, operatorWorkspaceDigest } from './operator-signals'
import { compositeTick } from './composite-signals'
import { isRecord } from './lib/type-guards'
import { normalizeKeeperApprovalAuditReceipt } from './lib/keeper-approval-audit'
import { showToast } from './components/common/toast'
import type { ErrorCode } from './types/error'
import { parseAgentCorePayloadOrNull } from './schemas/sse-event-payload'
import { hydrateAgentCoreTelemetrySample } from './agent-core-telemetry-store'
import { sseEventFamily, withoutMascNamespace } from './lib/sse-event-type'
import {
  SSE_APPROVAL_AUDIT_EVENT,
  SSE_APPROVAL_PENDING_EVENT,
  SSE_APPROVAL_RESOLVED_EVENT,
  SSE_APPROVAL_SUMMARY_UPDATED_EVENT,
} from './schemas/sse'
import { route } from './router'
import { routeWantsRefreshTarget, type RouteRefreshTarget } from './refresh-scope'
import {
  PERIODIC_REFRESH_DEV_MS,
  PERIODIC_REFRESH_PROD_MS,
  SSE_ACTIVITY_DEBOUNCE_MS,
  SSE_DEFAULT_DEBOUNCE_MS,
  SSE_KEEPER_OPERATOR_DEBOUNCE_MS,
  SSE_KEEPER_THREAD_DEBOUNCE_MS,
  SSE_RECONNECT_RETRY_MS,
} from './config/constants'

// --- Refresh function registration (avoids circular imports) ---

let _refreshGateFn: ((opts?: { force?: boolean }) => void) | null = null
export function registerGateRefresh(fn: (opts?: { force?: boolean }) => void): void {
  _refreshGateFn = fn
}

let _observeGateAuditReceiptFn: ((
  receipts: KeeperApprovalAuditReceipt[],
  context: { id: string | null; transport: 'sse' },
) => void) | null = null

export function registerGateAuditReceiptObserver(
  fn: (
    receipts: KeeperApprovalAuditReceipt[],
    context: { id: string | null; transport: 'sse' },
  ) => void,
): void {
  _observeGateAuditReceiptFn = fn
}

let _refreshOperatorFn: (() => void) | null = null
let operatorSnapshotRefreshPending = false

export function registerOperatorRefresh(fn: () => void): void {
  _refreshOperatorFn = fn
  if (operatorSnapshotRefreshPending) {
    requestOperatorSnapshotRefresh('operator_snapshot_registration_drain')
  }
}

let _refreshMissionFn: (() => void) | null = null
export function registerMissionRefresh(fn: () => void): void {
  _refreshMissionFn = fn
}

let _keeperTurnRefreshFn: ((keeperName: string) => void) | null = null
export function registerKeeperTurnRefresh(fn: (keeperName: string) => void): void {
  _keeperTurnRefreshFn = fn
}

// Queue push is an invalidation signal. Keeper-scoped read models register
// their authoritative re-read here instead of reconstructing queue state from
// event deltas.
const _refreshKeeperWaitingInventoryFns = new Set<(keeperName: string) => void>()
export function registerKeeperWaitingInventoryRefresh(
  fn: (keeperName: string) => void,
): () => void {
  _refreshKeeperWaitingInventoryFns.add(fn)
  return () => _refreshKeeperWaitingInventoryFns.delete(fn)
}

const _refreshActivityFns = new Set<() => void>()
export function registerActivityRefresh(fn: () => void): () => void {
  _refreshActivityFns.add(fn)
  return () => {
    _refreshActivityFns.delete(fn)
  }
}

const _refreshWorkspaceMessageFns = new Set<() => void>()
export function registerWorkspaceMessagesRefresh(fn: () => void): () => void {
  _refreshWorkspaceMessageFns.add(fn)
  return () => {
    _refreshWorkspaceMessageFns.delete(fn)
  }
}

const _refreshInternalAgentFns = new Set<() => void>()
export function registerInternalAgentRefresh(fn: () => void): () => void {
  _refreshInternalAgentFns.add(fn)
  return () => {
    _refreshInternalAgentFns.delete(fn)
  }
}

// IDE workspace live-refresh subscribers. The app-lifetime workspace-store
// singleton registers here so a keeper's file edits / tool runs refresh the
// tree/diff/file view without a re-navigation. A Set (not a single slot)
// keeps parity with registerActivityRefresh and tolerates a test store being
// registered alongside a production one during suite overlap.
const _refreshIdeFns = new Set<() => void>()
export function registerIdeWorkspaceRefresh(fn: () => void): () => void {
  _refreshIdeFns.add(fn)
  return () => {
    _refreshIdeFns.delete(fn)
  }
}

let _refreshBoardHearthsFn: (() => void) | null = null
export function registerBoardHearthsRefresh(fn: () => void): () => void {
  _refreshBoardHearthsFn = fn
  return () => {
    if (_refreshBoardHearthsFn === fn) _refreshBoardHearthsFn = null
  }
}

// The fusion detail browser reads the board-sink posts, not the run registry,
// and post_created carries only a 200-char preview with no meta — so the run's
// panels and judge cannot be built from the event. Refetch instead, which is
// what the surface's manual Refresh does (#21822).
let _refreshFusionBoardFn: (() => void) | null = null
export function registerFusionBoardRefresh(fn: () => void): () => void {
  _refreshFusionBoardFn = fn
  return () => {
    if (_refreshFusionBoardFn === fn) _refreshFusionBoardFn = null
  }
}

// --- Debounced scheduling ---

const _debounceTimers: Record<string, ReturnType<typeof setTimeout>> = {}

function scheduleRefresh(key: string, fn: () => void, delayMs = SSE_DEFAULT_DEBOUNCE_MS): void {
  if (_debounceTimers[key]) clearTimeout(_debounceTimers[key])
  _debounceTimers[key] = setTimeout(() => {
    fn()
    delete _debounceTimers[key]
  }, delayMs)
}

function requestOperatorSnapshotRefresh(key: string): void {
  if (_refreshOperatorFn) {
    operatorSnapshotRefreshPending = false
    scheduleRefresh(key, () => _refreshOperatorFn?.(), 0)
  } else {
    operatorSnapshotRefreshPending = true
  }
}

// --- Declarative event routing ---
// Simple events that map directly to a debounced refresh target.
// Complex events (conditional logic, async imports) use named handlers below.

type RefreshTarget = RouteRefreshTarget

interface SimpleRoute {
  target: RefreshTarget
  debounceMs?: number
  force?: boolean
}

// Route table maps server-push event type → refresh target. Only entries whose
// corresponding server emitter exists in lib/ are kept; dead keys were
// removed after cross-referencing the OCaml sources under lib/.
const SIMPLE_ROUTES: Record<string, SimpleRoute> = {
  // Broadcasts — emitted by lib/mcp_tool_runtime_comm.ml
  broadcast:           { target: 'execution' },
  // Keeper lifecycle (also triggers operator refresh via handler)
  keeper_handoff:       { target: 'execution', force: true },
  keeper_phase_changed: { target: 'execution', force: true },
  // A turn-complete hook precedes the durable TurnRecord commit and does not
  // mutate the execution cache. The selected Keeper is refreshed through the
  // scoped status reader in [handleKeeperLifecycle]; the proactive canonical
  // execution snapshot updates the roster without a per-turn global rebuild.
  // Board content — emitted by lib/mcp_tool_runtime_board.ml
  board_post:          { target: 'board' },
  'masc/board_post':    { target: 'board' },
  board_comment:        { target: 'board' },
  'masc/board_comment': { target: 'board' },
  board_delete:         { target: 'board' },
  'masc/board_delete':  { target: 'board' },
  // Board notifications — emitted by lib/server/server_bootstrap_loops.ml
  // via JSON-RPC method="notifications/board" (unwrapped to params.type)
  post_created:         { target: 'board' },
  comment_added:        { target: 'board' },
  post_voted:           { target: 'board' },
  comment_voted:        { target: 'board' },
  reaction_changed:     { target: 'board' },
  // Observatory activity telemetry
  activity:             { target: 'activity', debounceMs: SSE_ACTIVITY_DEBOUNCE_MS },
  // Fusion run registry — emitted by lib/fusion/fusion_sink.ml broadcast_run_status.
  // Without this entry the live WS router dropped the event and the run-status
  // panel only refreshed on the ~120s periodic poll / route revisit (RFC-0266 Phase 4).
  fusion_run_status:    { target: 'fusion' },
  internal_agent_runs_changed: { target: 'internalAgents', debounceMs: 0 },
}

const BOARD_HEARTH_REFRESH_EVENTS = new Set([
  'board_post',
  'masc/board_post',
  'board_delete',
  'masc/board_delete',
  'post_created',
])

// Prefix patterns for events that use startsWith matching
const PREFIX_ROUTES: Array<{ prefix: string; target: RefreshTarget }> = [
  { prefix: 'task_',      target: 'execution' },
  { prefix: 'masc/task_', target: 'execution' },
  { prefix: 'activity_',  target: 'activity' },
]

const REFRESH_FNS: Record<RefreshTarget, () => void> = {
  execution: () => { void refreshExecution() },
  board:     () => { void refreshBoard() },
  operator:  () => _refreshOperatorFn?.(),
  activity:  () => {
    for (const fn of _refreshActivityFns) fn()
  },
  fusion:    () => { void refreshFusionRuns() },
  internalAgents: () => {
    for (const fn of _refreshInternalAgentFns) fn()
  },
  ide:       () => {
    for (const fn of _refreshIdeFns) fn()
  },
}

function scheduleTargetRefresh(
  target: RefreshTarget,
  fn: () => void,
  delayMs?: number,
): void {
  if (!routeWantsRefreshTarget(route.value, target)) return
  scheduleRefresh(target, fn, delayMs)
}

function scheduleFusionBoardRefresh(delayMs = SSE_DEFAULT_DEBOUNCE_MS): void {
  if (!_refreshFusionBoardFn) return
  if (!routeWantsRefreshTarget(route.value, 'fusion')) return
  scheduleRefresh('fusion-board', () => {
    _refreshFusionBoardFn?.()
  }, delayMs)
}

function scheduleBoardHearthsRefresh(delayMs = SSE_DEFAULT_DEBOUNCE_MS): void {
  if (!_refreshBoardHearthsFn) return
  if (!routeWantsRefreshTarget(route.value, 'board')) return
  scheduleRefresh('board-hearths', () => {
    _refreshBoardHearthsFn?.()
  }, delayMs)
}

// Server-push events after which a keeper may have changed workspace files: tool runs
// (which include Edit/Write) and turn completion (a coarser backstop that also
// catches edits whose per-call event was coalesced). All already reach the
// dashboard live; the IDE just never listened. keeper_tool_call already exists
// in the fixed event-type allowlist (schemas/sse.ts) and is broadcast by
// lib/keeper_tools_agent_core_handler_telemetry.ml.
const IDE_WORKSPACE_REFRESH_EVENTS = new Set([
  'keeper_tool_call',
  'keeper_turn_complete',
])

/**
 * Fire the IDE workspace-store's live refresh, debounced and scoped to the
 * `code` surface. The store re-fetches tree/diff/file/blame from
 * the same HTTP endpoints it already uses; these are idempotent (server is the
 * SSOT), so a coalesced refresh is safe. Off the code tab this is a no-op, so
 * the singleton store does not fetch in the background.
 */
function scheduleIdeWorkspaceRefresh(): void {
  if (_refreshIdeFns.size === 0) return
  if (!routeWantsRefreshTarget(route.value, 'ide')) return
  scheduleRefresh('ide-workspace', REFRESH_FNS.ide)
}

// --- Named handlers for complex events ---

const KEEPER_LIFECYCLE_EVENTS = new Set([
  'keeper_handoff', 'keeper_turn_complete',
  'keeper_phase_changed',
])

function normalizeMascEventType(type: string): string {
  return withoutMascNamespace(type)
}

/** Hydrate project-snapshot signals directly from a push payload — zero HTTP fetch. */
function handleNamespaceTruthSnapshot(payload: unknown): void {
  try {
    const normalized = normalizeNamespaceTruth(payload)
    namespaceTruth.value = normalized
    namespaceTruthError.value = null
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.root.status ?? null,
    )
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'invalid project snapshot'
    namespaceTruth.value = null
    namespaceTruthError.value = detail
    console.warn('[server-push] project-snapshot hydration failed', detail)
  }
}

/** Hydrate execution signals directly from a push payload — zero HTTP fetch. */
function handleExecutionSnapshot(payload: unknown): void {
  try {
    if (!isRecord(payload)) throw new Error('execution snapshot payload is invalid')
    if (payload.execution_invalidated === true) {
      const epoch = payload.execution_publication_epoch
      const generation = payload.execution_publication_generation
      if (
        typeof epoch !== 'string'
        || epoch.trim() === ''
        || typeof generation !== 'number'
        || !Number.isSafeInteger(generation)
        || generation < 0
        || !invalidateExecutionSnapshotGeneration(epoch, generation)
      ) {
        throw new Error('execution invalidation generation is invalid')
      }
      void refreshExecution({ force: true })
      return
    }
    hydrateExecutionSnapshot(payload as DashboardExecutionResponse)
  } catch (err) {
    console.warn('[server-push] execution snapshot hydration failed, will fallback to HTTP', err instanceof Error ? err.message : '')
  }
}

function failOperatorSnapshotHydration(detail: string): void {
  operatorSnapshot.value = null
  operatorError.value = detail
}

function handleOperatorSnapshot(payload: unknown): void {
  try {
    operatorSnapshot.value = normalizeOperatorSnapshot(payload)
    operatorError.value = null
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'invalid operator snapshot'
    failOperatorSnapshotHydration(detail)
    console.warn('[server-push] operator snapshot hydration failed', detail)
  }
}

function handleOperatorDigest(payload: unknown): void {
  try {
    operatorWorkspaceDigest.value = normalizeOperatorDigest(payload)
  } catch (err) {
    console.warn('[server-push] operator digest hydration failed', err instanceof Error ? err.message : '')
  }
}

// P2 silent-failure fix: previously the dynamic import retried on every
// Transport-health push event with only console.debug on failure (hidden
// from default DevTools view).  Two improvements:
//   1. Cache the imported module so failure is signalled exactly once
//      per session, not on every push.
//   2. Promote the failure log to console.warn so operators see it
//      when investigating "transport health widget is missing/stale."
let transportHealthModule: Promise<typeof TransportHealth> | null = null
let transportHealthImportFailed = false

function handleTransportHealth(payload: unknown): void {
  if (transportHealthImportFailed) return
  if (transportHealthModule === null) {
    transportHealthModule = import('./components/transport-health')
  }
  void transportHealthModule
    .then(({ hydrateTransportHealthFromSSE }) => {
      hydrateTransportHealthFromSSE(payload)
    })
    .catch((err: unknown) => {
      transportHealthImportFailed = true
      console.warn(
        '[server-push] transport health module import failed — widget hydration disabled for this session',
        err,
      )
    })
}

function handleKeeperHeartbeat(event: { name?: string; ts_unix?: number }): void {
  if (!event.name) return
  const newTs = event.ts_unix ? event.ts_unix * 1000 : Date.now()
  const existingTs = keeperHeartbeats.value.get(event.name)
  if (existingTs === newTs) return
  const next = new Map(keeperHeartbeats.value)
  next.set(event.name, newTs)
  keeperHeartbeats.value = next
}

function handleKeeperLifecycle(event: { type: string; name?: string }): void {
  if (routeWantsRefreshTarget(route.value, 'operator')) {
    scheduleRefresh('operator', () => _refreshOperatorFn?.(), SSE_KEEPER_OPERATOR_DEBOUNCE_MS)
  }

  // keeper_turn_complete is an agent-core hook event that can precede the durable
  // TurnRecord commit, so it refreshes status only. Transcript freshness is
  // driven by the post-commit keeper_chat_appended invalidation.
  if (normalizeMascEventType(event.type) === 'keeper_turn_complete') {
    const keeperName = event.name ?? ''
    if (!keeperName) return
    if (_keeperTurnRefreshFn) {
      scheduleRefresh(
        `keeper_thread_${keeperName}`,
        () => _keeperTurnRefreshFn?.(keeperName),
        SSE_KEEPER_THREAD_DEBOUNCE_MS,
      )
    }
  }
}

function handleGate(opts?: { force?: boolean }): void {
  _refreshGateFn?.(opts)
}

async function refreshActiveRoute(): Promise<void> {
  try {
    const { refreshForRoute } = await import('./tab-refresh')
    refreshForRoute(route.value)
  } catch (err) {
    console.debug('[server-push] tab-refresh unavailable, using fallback refreshes', err instanceof Error ? err.message : '')
    _refreshOperatorFn?.()
    _refreshMissionFn?.()
  }
}

// --- WebSocket reconnection handler ---

let activeOperatorSnapshotEpoch: string | null = null
let latestOperatorSnapshotGeneration: number | null = null
let latestOperatorSnapshotComputeSequence: number | null = null
let latestOperatorSnapshotTerminalSequence: number | null = null
const retiredOperatorSnapshotEpochs = new Set<string>()

function handleReconnect(): void {
  const disconnectedMs = dashboardWsLastDisconnectedAt.value > 0
    ? Date.now() - dashboardWsLastDisconnectedAt.value
    : 0
  const durationSec = Math.round(disconnectedMs / 1000)
  const label = durationSec > 0 ? `${durationSec}초 단절 후 재연결됨` : '서버 연결 복구됨'
  showToast(label, 'success', 3000)

  // Refresh all data to recover events missed during disconnect.
  // If the server is still warming up after restart, the first fetch may fail.
  // Schedule a single retry after 3s to cover the warm-up window.
  invalidateDashboardCache()
  resetExecutionSnapshotGeneration()
  void refreshExecution({ force: true })
  pauseQueuedAgentCoreRuntimeIngress()
  void hydrateAfterReconnect()
    .finally(() => {
      resumeQueuedAgentCoreRuntimeIngress()
    })
}

async function hydrateAfterReconnect(): Promise<void> {
  try {
    const { replayAgentCoreRuntimeTelemetry } = await import('./agent-core-runtime-store')
    await replayAgentCoreRuntimeTelemetry()
  } catch (err) {
    console.warn('[server-push] reconnect Agent Core replay failed', err instanceof Error ? err.message : err)
  }
  requestNamespaceTruthNow()
  // Recover approval-queue state that may have changed while disconnected: the
  // always-visible nav-rail approvals badge reads gateData regardless of
  // the active surface, so an approval that arrived (or resolved) during the
  // gap must be re-fetched on reconnect, not only on the Gate surface.
  handleGate()
  // Recover keeper_chat_appended events that fell outside the server replay
  // buffer while disconnected. The WS channel cannot re-deliver them, so the
  // open conversation panel must re-fetch its transcript. Route and periodic
  // refreshes deliberately skip this (guard-respecting no-op to avoid polling),
  // so force it here — reconnect is the only path that knows a gap may exist.
  // Route-independent: covers the open keeper panel on any tab.
  void import('./keeper-runtime')
    .then(mod => { mod.refreshActiveKeeperChatHistory({ force: true }) })
    .catch(err =>
      console.warn('[server-push] reconnect keeper chat re-hydration unavailable', err instanceof Error ? err.message : err),
    )
  void refreshDashboard({ force: true }).catch(err =>
    console.warn('[server-push] reconnect dashboard refresh failed', err instanceof Error ? err.message : err),
  )
  void refreshActiveRoute().catch(err =>
    console.warn('[server-push] reconnect route refresh failed', err instanceof Error ? err.message : err),
  )
  // Safety-net retry: if project-snapshot fetch failed (e.g. server warm-up),
  // the scheduler's error signal will be set. Retry once after delay.
  setTimeout(() => {
    if (namespaceTruthError.value) {
      requestNamespaceTruthNow()
    }
    void refreshDashboard({ force: true }).catch(retryErr =>
      console.warn(
        '[server-push] reconnect dashboard retry failed',
        retryErr instanceof Error ? retryErr.message : retryErr,
      ),
    )
    void refreshActiveRoute().catch(retryErr =>
      console.warn('[server-push] reconnect route retry failed', retryErr instanceof Error ? retryErr.message : retryErr),
    )
  }, SSE_RECONNECT_RETRY_MS)
}

// --- Board incremental hydration ---
// When a post_created push event carries content and the board is sorted by
// recent, we can prepend the post directly — zero HTTP fetch. For other sort
// modes the position is algorithm-dependent so we fall through to refreshBoard.

function handleBoardPostCreated(event: SSEEvent): boolean {
  if (boardSortMode.value !== 'recent') return false
  const postId = event.post_id as string | undefined
  const content = event.content as string | undefined
  if (!postId || !content) return false
  if (boardPosts.value.some(p => p.id === postId)) return false
  const eventHearth = event.hearth?.trim() ?? ''
  if (!eventMatchesActiveBoardFilters(event)) return false
  if (eventHearth) scheduleBoardHearthsRefresh()

  const now = new Date().toISOString()
  const post: BoardPost = {
    id: postId,
    author: event.author ?? '',
    author_identity: event.author_identity ?? null,
    title: event.title ?? '',
    body: content,
    tags: [],
    created_at: now,
    updated_at: now,
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    post_kind: boardPostKindFromEvent(event),
    hearth: eventHearth || undefined,
  }
  boardPosts.value = [post, ...boardPosts.value]
  // The server-side offset-based list has shifted by one because of this real
  // persisted post, so advance the pagination cursor to avoid requesting the
  // same posts again on the next load-more fetch.
  boardOffset.value += 1
  return true
}

function boardPostKindFromEvent(event: SSEEvent): BoardPost['post_kind'] {
  const rawKind = (typeof event.post_kind === 'string' ? event.post_kind : 'direct').toLowerCase()
  return rawKind === 'system' || rawKind === 'automation' ? rawKind : 'direct'
}

function eventMatchesActiveBoardFilters(event: SSEEvent): boolean {
  const hearthFilter = boardHearthFilter.value.trim()
  if (hearthFilter !== '' && (event.hearth?.trim() ?? '') !== hearthFilter) return false

  // Author filtering is server-defined today, so a filtered view should be
  // reconciled through the board endpoint instead of guessing client-side.
  if (boardAuthorFilter.value.trim() !== '') return false

  if (typeof event.post_kind !== 'string' && (boardExcludeSystem.value || boardExcludeAutomation.value)) {
    return false
  }

  const postKind = boardPostKindFromEvent(event)
  if (postKind === 'system' && boardExcludeSystem.value) return false
  if (postKind === 'automation' && boardExcludeAutomation.value) return false
  return true
}

export function routeServerPushEvent(event: SSEEvent): void {
  if (hydrateServerPushEvent(event)) {
    return
  }

  const routedType = normalizeSSEDispatchType(event.type)
  if (
    normalizeMascEventType(routedType) === 'broadcast'
    || routedType === 'workspace_message_delivery_changed'
  ) {
    scheduleRefresh('workspace-messages', () => {
      for (const refresh of _refreshWorkspaceMessageFns) refresh()
    })
  }
  const simpleRoute = SIMPLE_ROUTES[routedType]
  if (simpleRoute) {
    const refreshFn =
      simpleRoute.force && simpleRoute.target === 'execution'
        ? () => { void refreshExecution({ force: true }) }
        : REFRESH_FNS[simpleRoute.target]
    scheduleTargetRefresh(
      simpleRoute.target,
      refreshFn,
      simpleRoute.debounceMs,
    )
    if (BOARD_HEARTH_REFRESH_EVENTS.has(routedType)) {
      scheduleBoardHearthsRefresh(simpleRoute.debounceMs)
    }
  }
  if (routedType === 'fusion_run_status') {
    scheduleTargetRefresh('internalAgents', REFRESH_FNS.internalAgents, 0)
  }

  for (const { prefix, target } of PREFIX_ROUTES) {
    if (routedType.startsWith(prefix)) {
      scheduleTargetRefresh(target, REFRESH_FNS[target])
      break
    }
  }

  if (KEEPER_LIFECYCLE_EVENTS.has(normalizeMascEventType(routedType))) {
    handleKeeperLifecycle(event)
  }

  if (IDE_WORKSPACE_REFRESH_EVENTS.has(normalizeMascEventType(routedType))) {
    scheduleIdeWorkspaceRefresh()
  }

  // summary_updated carries the Auto Judge verdict transition (summary
  // pending -> available, disposition in_flight -> settled). Without it the
  // queue only refreshes on arrival and terminal resolution, so a verdict of
  // require_human leaves the row rendering "generating summary" until the
  // periodic sweep (120-180s) even though the judge settled in ~2s.
  const approvalRefreshEvent =
    event.type === SSE_APPROVAL_PENDING_EVENT
    || event.type === SSE_APPROVAL_RESOLVED_EVENT
    || event.type === SSE_APPROVAL_SUMMARY_UPDATED_EVENT

  if (
    (event.type === SSE_APPROVAL_PENDING_EVENT
      || event.type === SSE_APPROVAL_RESOLVED_EVENT
      || event.type === SSE_APPROVAL_AUDIT_EVENT)
    && isRecord(event.payload)
  ) {
    const receipt = normalizeKeeperApprovalAuditReceipt(event.payload.audit)
    const receiptMatchesEnvelope = receipt !== null && (
      (event.type === SSE_APPROVAL_PENDING_EVENT && receipt.event === 'pending')
      || (event.type === SSE_APPROVAL_RESOLVED_EVENT && receipt.event === 'resolved')
      || (
        event.type === SSE_APPROVAL_AUDIT_EVENT
        && (receipt.event === 'grant_consumed' || receipt.event === 'gate_allowed')
      )
    )
    if (receipt !== null && receiptMatchesEnvelope) {
      const id = typeof event.payload.id === 'string' && event.payload.id.trim() !== ''
        ? event.payload.id
        : null
      _observeGateAuditReceiptFn?.([receipt], { id, transport: 'sse' })
    }
  }

  if (
    sseEventFamily(event.type) === 'decision'
    || event.type === 'runtime_param_changed'
    || approvalRefreshEvent
  ) {
    if (route.value.tab === 'command') {
      scheduleRefresh('command_route', () => {
        void refreshActiveRoute()
      })
    }
    if (_refreshGateFn) {
      const opts = approvalRefreshEvent ? { force: true } : undefined
      scheduleRefresh('gate', () => void handleGate(opts))
    }
  }
}

export function hydrateServerPushEvent(event: SSEEvent): boolean {
  if (event.type === 'project_snapshot' && event.payload) {
    handleNamespaceTruthSnapshot(event.payload)
    return true
  }

  if (event.type === 'execution_snapshot' && event.payload) {
    handleExecutionSnapshot(event.payload)
    return true
  }

  if (event.type === 'operator_snapshot') {
    if (!isRecord(event.payload)) {
      failOperatorSnapshotHydration('operator snapshot payload is invalid')
      requestOperatorSnapshotRefresh('operator_snapshot_invalid_payload')
      return true
    }
    const payload = event.payload
    const epoch = payload.snapshot_epoch
    const generation = payload.snapshot_generation
    const computeSequence = payload.snapshot_compute_sequence
    const terminalSequence = payload.snapshot_terminal_sequence
    if (
      typeof epoch !== 'string'
      || epoch.length === 0
      || typeof generation !== 'number'
      || !Number.isSafeInteger(generation)
      || typeof computeSequence !== 'number'
      || !Number.isSafeInteger(computeSequence)
      || typeof terminalSequence !== 'number'
      || !Number.isSafeInteger(terminalSequence)
    ) {
      failOperatorSnapshotHydration('operator snapshot ordering is missing')
      requestOperatorSnapshotRefresh('operator_snapshot_missing_ordering')
      return true
    }
    if (
      typeof epoch === 'string'
      && epoch.length > 0
    ) {
      if (retiredOperatorSnapshotEpochs.has(epoch)) {
        return true
      }
      if (activeOperatorSnapshotEpoch !== epoch) {
        if (activeOperatorSnapshotEpoch !== null) {
          retiredOperatorSnapshotEpochs.add(activeOperatorSnapshotEpoch)
        }
        activeOperatorSnapshotEpoch = epoch
        latestOperatorSnapshotGeneration = null
        latestOperatorSnapshotComputeSequence = null
        latestOperatorSnapshotTerminalSequence = null
      }
      if (
        latestOperatorSnapshotGeneration !== null
        && generation < latestOperatorSnapshotGeneration
      ) {
        return true
      }
      if (latestOperatorSnapshotGeneration !== generation) {
        latestOperatorSnapshotGeneration = generation
        latestOperatorSnapshotComputeSequence = null
        latestOperatorSnapshotTerminalSequence = null
      }
      if (
        typeof terminalSequence === 'number'
        && Number.isSafeInteger(terminalSequence)
      ) {
        if (
          latestOperatorSnapshotTerminalSequence !== null
          && terminalSequence < latestOperatorSnapshotTerminalSequence
        ) {
          return true
        }
        latestOperatorSnapshotTerminalSequence = terminalSequence
      }
      if (
        typeof computeSequence === 'number'
        && Number.isSafeInteger(computeSequence)
      ) {
        if (
          latestOperatorSnapshotComputeSequence !== null
          && computeSequence < latestOperatorSnapshotComputeSequence
        ) {
          return true
        }
        latestOperatorSnapshotComputeSequence = computeSequence
      }
      if (payload.status === 'invalidated') {
        failOperatorSnapshotHydration('operator snapshot invalidated')
        requestOperatorSnapshotRefresh('operator_snapshot_invalidation')
        return true
      }
    }
    handleOperatorSnapshot(event.payload)
    return true
  }
  if (event.type === 'operator_digest' && event.payload) {
    handleOperatorDigest(event.payload)
    return true
  }
  if (event.type === 'transport_health_snapshot' && event.payload) {
    handleTransportHealth(event.payload)
    return true
  }

  if (event.type === 'agent_core:agent_failed') {
    const parsed = parseAgentCorePayloadOrNull(event.type, event.payload)
    if (!parsed || parsed.kind !== 'agent_failed') return false
    const { payload: p } = parsed
    void import('./components/common/error-notification')
      .then(({ handleAgentFailed }) => {
        handleAgentFailed({
          agentName: (p.agent_name || event.agent_name) ?? 'unknown',
          taskId: p.task_id,
          errorCode: p.error_code as ErrorCode | undefined,
          error: (p.error || event.error_text) ?? '알 수 없는 오류',
        })
      })
      .catch(err => {
        console.debug('[server-push] agent-failed notification unavailable', err instanceof Error ? err.message : '')
      })
    return false
  }

  if (event.type === 'keeper_heartbeat') {
    handleKeeperHeartbeat(event)
    return true
  }

  // The payload is the sample itself (schema-validated at the boundary), so
  // the read model hydrates from the push directly — zero HTTP fetch. The
  // runtime monitor renders latestAgentCoreTelemetrySample; nothing to refresh.
  if (event.type === 'agent_core_telemetry_sample') {
    hydrateAgentCoreTelemetrySample(event)
    return true
  }

  // Signal-only freshness tick for keeper composite state. The push payload
  // carries only the keeper name and a wall-clock timestamp; it is *not* the
  // authoritative composite snapshot. Consumers that need the new state must
  // observe [compositeTick] and re-fetch [/api/v1/keepers/:name/composite]
  // from the registry. See docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md §Read Model Rules.
  if (event.type === 'keeper_composite_changed') {
    const payload = event as unknown as { name?: string; ts_unix?: number }
    const name = typeof payload.name === 'string' ? payload.name : ''
    const ts_unix = typeof payload.ts_unix === 'number' ? payload.ts_unix : Date.now() / 1000
    compositeTick.value = { name, ts_unix }
    return true
  }

  if (event.type === 'keeper_chat_appended') {
    const payload = event as unknown as { name?: string; audio?: unknown; blocks?: unknown }
    const name = typeof payload.name === 'string' ? payload.name : ''
    if (name) {
      // Dynamic import keeps sse-store decoupled from the keeper action
      // layer (same pattern as the agent-failed notification above).
      void import('./keeper-runtime')
        .then(mod => { mod.noteKeeperChatAppended(name, payload.audio, payload.blocks) })
        .catch(err => {
          console.debug('[server-push] keeper chat refresh unavailable', err instanceof Error ? err.message : '')
        })
    }
    return true
  }

  if (event.type === 'keeper_waiting_inventory_changed') {
    const keeperName = event.keeper_name?.trim() ?? ''
    if (keeperName) {
      for (const refresh of _refreshKeeperWaitingInventoryFns) refresh(keeperName)
    }
    return true
  }

  if (event.type === 'post_created') {
    // Before the board branch: the fusion surface needs the refetch whether or
    // not the board could prepend, and the prepend path returns early.
    scheduleFusionBoardRefresh()
    if (handleBoardPostCreated(event)) return true
  }

  return false
}

function eventPayloadRecord(payload: unknown): Record<string, unknown> {
  return isRecord(payload) ? payload : { payload }
}

export function hydrateDashboardSlice(_slice: string, payload: unknown, eventType?: string): void {
  switch (eventType) {
    case 'project_snapshot':
    case 'execution_snapshot':
    case 'operator_snapshot':
    case 'operator_digest':
    case 'transport_health_snapshot':
      hydrateServerPushEvent({ type: eventType, payload } as SSEEvent)
      return
  }
  if (eventType) {
    routeServerPushEvent({
      type: eventType,
      ...eventPayloadRecord(payload),
    } as SSEEvent)
    return
  }

  // Dashboard deltas require an event type so the typed handler is explicit.
}

// --- WebSocket server-push reaction setup ---

export function setupServerPushReaction(): () => void {
  const unsubReconnect = dashboardWsReconnectCount.subscribe((count) => {
    if (count > 0 && dashboardWsReady.value) {
      handleReconnect()
    }
  })

  return () => {
    unsubReconnect()
    for (const key of Object.keys(_debounceTimers)) {
      clearTimeout(_debounceTimers[key])
      delete _debounceTimers[key]
    }
  }
}

// --- Periodic refresh ---

const PERIODIC_REFRESH_MS = import.meta.env.DEV
  ? PERIODIC_REFRESH_DEV_MS
  : PERIODIC_REFRESH_PROD_MS

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    // Fallback only. While the WS is delivering, every route surface this
    // would refetch is already hydrated by push, so firing anyway just
    // duplicates the traffic. Previously only invalidateDashboardCache()
    // was gated and the two refresh calls ran unconditionally.
    if (dashboardWsReady.value) return
    invalidateDashboardCache()
    requestNamespaceTruth()
    void refreshActiveRoute().catch(err =>
      console.warn('[periodic] route refresh failed', err instanceof Error ? err.message : err),
    )
  }, PERIODIC_REFRESH_MS)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}

/** Cancel all pending server-push refresh timers.
 *  Call on route change to prevent stale fetches from firing after the user
 *  navigates to a different tab. */
export function cancelPendingServerPushRefreshes(): void {
  for (const key of Object.keys(_debounceTimers)) {
    clearTimeout(_debounceTimers[key])
    delete _debounceTimers[key]
  }
}
