// SSE event reaction and periodic refresh — extracted from store.ts
// Routes SSE events to the minimal refresh function needed.
//
// Event routing uses a declarative map for simple refresh-only events,
// and named handlers for events with custom logic (conditional hydration,
// async imports, signal-only updates).

import {
  lastEvent,
  connected,
  reconnectCount,
  lastDisconnectedAt,
  pauseQueuedOasRuntimeIngress,
  resumeQueuedOasRuntimeIngress,
} from './sse'
import type {
  BoardPost,
  DashboardExecutionResponse,
  DashboardMemoryResponse,
  DashboardPlanningResponse,
  DashboardShellResponse,
  SSEEvent,
} from './types'
import {
  keeperHeartbeats,
  invalidateDashboardCache,
  hydrateBoardSnapshot,
  hydrateShellSnapshot,
  hydrateExecutionSnapshot,
  hydratePlanningSnapshot,
  refreshDashboard,
  refreshExecution,
  refreshBoard,
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
import { operatorSnapshot, operatorRoomDigest } from './operator-signals'
import { compositeTick, hydrateFleetCompositeSnapshot } from './composite-signals'
import { hydrateGoalTreeSnapshot } from './goal-tree-state'
import { showToast } from './components/common/toast'
import type { ErrorCode } from './types/error'
import { route } from './router'
import { routeWantsRefreshTarget } from './refresh-scope'
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

let _refreshGovernanceFn: (() => void) | null = null
export function registerGovernanceRefresh(fn: () => void): void {
  _refreshGovernanceFn = fn
}

let _refreshOperatorFn: (() => void) | null = null
export function registerOperatorRefresh(fn: () => void): void {
  _refreshOperatorFn = fn
}

let _refreshMissionFn: (() => void) | null = null
export function registerMissionRefresh(fn: () => void): void {
  _refreshMissionFn = fn
}

let _keeperTurnRefreshFn: ((keeperName: string) => void) | null = null
export function registerKeeperTurnRefresh(fn: (keeperName: string) => void): void {
  _keeperTurnRefreshFn = fn
}

const _refreshActivityFns = new Set<() => void>()
export function registerActivityRefresh(fn: () => void): () => void {
  _refreshActivityFns.add(fn)
  return () => {
    _refreshActivityFns.delete(fn)
  }
}

let _refreshBoardHearthsFn: (() => void) | null = null
export function registerBoardHearthsRefresh(fn: () => void): () => void {
  _refreshBoardHearthsFn = fn
  return () => {
    if (_refreshBoardHearthsFn === fn) _refreshBoardHearthsFn = null
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

// --- Declarative event routing ---
// Simple events that map directly to a debounced refresh target.
// Complex events (conditional logic, async imports) use named handlers below.

type RefreshTarget = 'execution' | 'board' | 'operator' | 'activity'

interface SimpleRoute {
  target: RefreshTarget
  debounceMs?: number
}

// Route table maps SSE event type → refresh target. Only entries whose
// corresponding server emitter exists in lib/ are kept; dead keys were
// removed after cross-referencing the OCaml sources under lib/.
const SIMPLE_ROUTES: Record<string, SimpleRoute> = {
  // Agent lifecycle — emitted by lib/tool_inline_dispatch_room.ml
  'masc/agent_joined':  { target: 'execution' },
  'masc/agent_left':    { target: 'execution' },
  // Broadcasts — emitted by lib/tool_inline_dispatch_comm.ml
  'masc/broadcast':     { target: 'execution' },
  // Keeper lifecycle (also triggers operator refresh via handler)
  keeper_handoff:       { target: 'execution' },
  keeper_compaction:    { target: 'execution' },
  keeper_phase_changed: { target: 'execution' },
  // Board content — emitted by lib/tool_inline_dispatch_extra.ml
  'masc/board_post':    { target: 'board' },
  board_comment:        { target: 'board' },
  'masc/board_delete':  { target: 'board' },
  // Board notifications — emitted by lib/server/server_bootstrap_loops.ml
  // via JSON-RPC method="notifications/board" (unwrapped to params.type)
  post_created:         { target: 'board' },
  comment_added:        { target: 'board' },
  post_voted:           { target: 'board' },
  comment_voted:        { target: 'board' },
  // Activity graph
  activity:             { target: 'activity', debounceMs: SSE_ACTIVITY_DEBOUNCE_MS },
}

// Prefix patterns for events that use startsWith matching
const PREFIX_ROUTES: Array<{ prefix: string; target: RefreshTarget }> = [
  { prefix: 'task_',      target: 'execution' },
  { prefix: 'masc/task_', target: 'execution' },
  { prefix: 'activity_',  target: 'activity' },
]

const REFRESH_FNS: Record<RefreshTarget, () => void> = {
  execution: () => { void refreshExecution() },
  board:     () => {
    void refreshBoard()
    _refreshBoardHearthsFn?.()
  },
  operator:  () => _refreshOperatorFn?.(),
  activity:  () => {
    for (const fn of _refreshActivityFns) fn()
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

function scheduleBoardHearthsRefresh(delayMs = SSE_DEFAULT_DEBOUNCE_MS): void {
  if (!_refreshBoardHearthsFn) return
  if (!routeWantsRefreshTarget(route.value, 'board')) return
  scheduleRefresh('board-hearths', () => {
    _refreshBoardHearthsFn?.()
  }, delayMs)
}

// --- Named handlers for complex events ---

const KEEPER_LIFECYCLE_EVENTS = new Set([
  'keeper_handoff', 'keeper_compaction', 'keeper_turn_complete', 'keeper_phase_changed',
])

function normalizeMascEventType(type: string): string {
  return type.startsWith('masc/') ? type.slice('masc/'.length) : type
}

const AUTORESEARCH_EVENTS = new Set([
  'autoresearch_cycle',
  'autoresearch_started',
  'autoresearch_stopped',
])

/** Hydrate project-snapshot signals directly from SSE payload — zero HTTP fetch. */
function handleNamespaceTruthSnapshot(payload: unknown): void {
  try {
    const normalized = normalizeNamespaceTruth(payload)
    namespaceTruth.value = normalized
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.root.status ?? null,
    )
  } catch (err) {
    console.debug('[SSE] project-snapshot hydration failed, will fallback to HTTP', err instanceof Error ? err.message : '')
  }
}

/** Hydrate execution signals directly from SSE payload — zero HTTP fetch. */
function handleExecutionSnapshot(payload: unknown): void {
  try {
    hydrateExecutionSnapshot(payload as DashboardExecutionResponse)
  } catch (err) {
    console.debug('[SSE] execution snapshot hydration failed, will fallback to HTTP', err instanceof Error ? err.message : '')
  }
}

function handleOperatorSnapshot(payload: unknown): void {
  try {
    operatorSnapshot.value = normalizeOperatorSnapshot(payload)
  } catch (err) {
    console.debug('[SSE] operator snapshot hydration failed', err instanceof Error ? err.message : '')
  }
}

function handleOperatorDigest(payload: unknown): void {
  try {
    operatorRoomDigest.value = normalizeOperatorDigest(payload)
  } catch (err) {
    console.debug('[SSE] operator digest hydration failed', err instanceof Error ? err.message : '')
  }
}

// P2 silent-failure fix: previously the dynamic import retried on every
// SSE transport-health event with only console.debug on failure (hidden
// from default DevTools view).  Two improvements:
//   1. Cache the imported module so failure is signalled exactly once
//      per session, not on every SSE tick.
//   2. Promote the failure log to console.warn so operators see it
//      when investigating "transport health widget is missing/stale."
let transportHealthModule: Promise<typeof import('./components/transport-health')> | null = null
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
        '[SSE] transport health module import failed — widget hydration disabled for this session',
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

  // keeper_turn_complete: re-hydrate active keeper's conversation + trajectory
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

function handleGovernance(): void {
  _refreshGovernanceFn?.()
}

async function refreshActiveRoute(): Promise<void> {
  try {
    const { refreshForRoute } = await import('./tab-refresh')
    refreshForRoute(route.value)
  } catch (err) {
    console.debug('[SSE] tab-refresh unavailable, using fallback refreshes', err instanceof Error ? err.message : '')
    _refreshOperatorFn?.()
    _refreshMissionFn?.()
  }
}

function activeAutoresearchRoute(): boolean {
  return route.value.tab === 'lab' && route.value.params.section === 'autoresearch'
}

// --- SSE reconnection handler ---

function handleReconnect(): void {
  const disconnectedMs = lastDisconnectedAt.value > 0
    ? Date.now() - lastDisconnectedAt.value
    : 0
  const durationSec = Math.round(disconnectedMs / 1000)
  const label = durationSec > 0 ? `${durationSec}초 단절 후 재연결됨` : '서버 연결 복구됨'
  showToast(label, 'success', 3000)

  // Refresh all data to recover events missed during disconnect.
  // If the server is still warming up after restart, the first fetch may fail.
  // Schedule a single retry after 3s to cover the warm-up window.
  invalidateDashboardCache()
  pauseQueuedOasRuntimeIngress()
  void hydrateAfterReconnect()
    .finally(() => {
      resumeQueuedOasRuntimeIngress()
    })
}

async function hydrateAfterReconnect(): Promise<void> {
  try {
    const { replayOasRuntimeTelemetry } = await import('./oas-runtime-store')
    await replayOasRuntimeTelemetry()
  } catch (err) {
    console.warn('[SSE] reconnect OAS replay failed', err instanceof Error ? err.message : err)
  }
  requestNamespaceTruthNow()
  void refreshDashboard({ force: true }).catch(err =>
    console.warn('[SSE] reconnect dashboard refresh failed', err instanceof Error ? err.message : err),
  )
  void refreshActiveRoute().catch(err =>
    console.warn('[SSE] reconnect route refresh failed', err instanceof Error ? err.message : err),
  )
  // Safety-net retry: if project-snapshot fetch failed (e.g. server warm-up),
  // the scheduler's error signal will be set. Retry once after delay.
  setTimeout(() => {
    if (namespaceTruthError.value) {
      requestNamespaceTruthNow()
    }
    void refreshDashboard({ force: true }).catch(retryErr =>
      console.warn(
        '[SSE] reconnect dashboard retry failed',
        retryErr instanceof Error ? retryErr.message : retryErr,
      ),
    )
    void refreshActiveRoute().catch(retryErr =>
      console.warn('[SSE] reconnect route retry failed', retryErr instanceof Error ? retryErr.message : retryErr),
    )
  }, SSE_RECONNECT_RETRY_MS)
}

// --- Board incremental hydration ---
// When a post_created SSE event carries content and the board is sorted by
// recent, we can prepend the post directly — zero HTTP fetch. For other sort
// modes the position is algorithm-dependent so we fall through to refreshBoard.

function handleBoardPostCreated(event: SSEEvent): boolean {
  if (boardSortMode.value !== 'recent') return false
  const postId = event.post_id as string | undefined
  const content = event.content as string | undefined
  if (!postId || !content) return false
  if (boardPosts.value.some(p => p.id === postId)) return false
  const eventHearth = event.hearth?.trim() ?? ''
  if (eventHearth) scheduleBoardHearthsRefresh()
  if (!eventMatchesActiveBoardFilters(event)) return false

  const now = new Date().toISOString()
  const post: BoardPost = {
    id: postId,
    author: event.author ?? '',
    author_identity: event.author_identity ?? null,
    title: event.title ?? '',
    body: content,
    content,
    tags: [],
    created_at: now,
    updated_at: now,
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    hearth: eventHearth || undefined,
  }
  boardPosts.value = [post, ...boardPosts.value]
  boardOffset.value = boardPosts.value.length
  return true
}

function eventMatchesActiveBoardFilters(event: SSEEvent): boolean {
  const hearthFilter = boardHearthFilter.value.trim()
  if (hearthFilter !== '' && (event.hearth?.trim() ?? '') !== hearthFilter) return false

  // Author filtering is server-defined today, so a filtered view should be
  // reconciled through the board endpoint instead of guessing client-side.
  if (boardAuthorFilter.value.trim() !== '') return false

  const rawKind = (event.post_kind ?? 'direct').toLowerCase()
  const postKind = rawKind === 'system' || rawKind === 'automation' ? rawKind : 'direct'
  if (postKind === 'system' && boardExcludeSystem.value) return false
  if (postKind === 'automation' && boardExcludeAutomation.value) return false
  return true
}

export function routeServerPushEvent(event: SSEEvent): void {
  if (hydrateServerPushEvent(event)) {
    return
  }

  const simpleRoute = SIMPLE_ROUTES[event.type]
  if (simpleRoute) {
    scheduleTargetRefresh(
      simpleRoute.target,
      REFRESH_FNS[simpleRoute.target],
      simpleRoute.debounceMs,
    )
  }

  for (const { prefix, target } of PREFIX_ROUTES) {
    if (event.type.startsWith(prefix)) {
      scheduleTargetRefresh(target, REFRESH_FNS[target])
      break
    }
  }

  if (KEEPER_LIFECYCLE_EVENTS.has(normalizeMascEventType(event.type))) {
    handleKeeperLifecycle(event)
  }

  if (AUTORESEARCH_EVENTS.has(event.type) && activeAutoresearchRoute()) {
    scheduleRefresh('autoresearch_route', () => {
      void refreshActiveRoute()
    }, SSE_DEFAULT_DEBOUNCE_MS)
  }

  if (
    event.type.startsWith('decision_')
    || event.type === 'governance_param_changed'
    || event.type === 'approval:pending'
    || event.type === 'approval:resolved'
  ) {
    if (route.value.tab === 'command') {
      scheduleRefresh('command_route', () => {
        void refreshActiveRoute()
      })
    }
    if (_refreshGovernanceFn) {
      scheduleRefresh('governance', () => void handleGovernance())
    }
  }
}

export function hydrateServerPushEvent(event: SSEEvent): boolean {
  if ((event.type === 'project_snapshot' || event.type === 'namespace_truth_snapshot' || event.type === 'room_truth_snapshot') && event.payload) {
    handleNamespaceTruthSnapshot(event.payload)
    return true
  }

  if (event.type === 'execution_snapshot' && event.payload) {
    handleExecutionSnapshot(event.payload)
    return true
  }

  if (event.type === 'operator_snapshot' && event.payload) {
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

  if (event.type === 'oas:agent_failed') {
    const p = (event.payload ?? {}) as Record<string, unknown>
    const rawCode = typeof p.error_code === 'string' ? p.error_code : undefined
    void import('./components/common/error-notification')
      .then(({ handleAgentFailed }) => {
        handleAgentFailed({
          agentName: typeof p.agent_name === 'string' ? p.agent_name
            : event.agent_name ?? 'unknown',
          taskId: typeof p.task_id === 'string' ? p.task_id : undefined,
          errorCode: rawCode as ErrorCode | undefined,
          error: typeof p.error === 'string' ? p.error
            : event.error_text ?? '알 수 없는 오류',
        })
      })
      .catch(err => {
        console.debug('[SSE] agent-failed notification unavailable', err instanceof Error ? err.message : '')
      })
    return false
  }

  if (event.type === 'keeper_heartbeat') {
    handleKeeperHeartbeat(event)
    return true
  }

  if (event.type === 'keeper_composite_changed') {
    const payload = event as unknown as { name?: string; ts_unix?: number }
    const name = typeof payload.name === 'string' ? payload.name : ''
    const ts_unix = typeof payload.ts_unix === 'number' ? payload.ts_unix : Date.now() / 1000
    compositeTick.value = { name, ts_unix }
    return true
  }

  if (event.type === 'post_created' && handleBoardPostCreated(event)) {
    return true
  }

  return false
}

function eventPayloadRecord(payload: unknown): Record<string, unknown> {
  return payload && typeof payload === 'object' && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : { payload }
}

export function hydrateDashboardSlice(slice: string, payload: unknown, eventType?: string): void {
  switch (eventType) {
    case 'project_snapshot':
    case 'namespace_truth_snapshot':
    case 'room_truth_snapshot':
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

  switch (slice) {
    case 'shell':
      hydrateShellSnapshot(payload as DashboardShellResponse, { light: true })
      return
    case 'namespace':
      hydrateServerPushEvent({ type: 'project_snapshot', payload } as SSEEvent)
      return
    case 'execution':
      hydrateServerPushEvent({ type: 'execution_snapshot', payload } as SSEEvent)
      return
    case 'operator': {
      const record = payload as { snapshot?: unknown; digest?: unknown }
      if (record.snapshot) {
        hydrateServerPushEvent({ type: 'operator_snapshot', payload: record.snapshot } as SSEEvent)
      }
      if (record.digest) {
        hydrateServerPushEvent({ type: 'operator_digest', payload: record.digest } as SSEEvent)
      }
      return
    }
    case 'transport':
      hydrateServerPushEvent({ type: 'transport_health_snapshot', payload } as SSEEvent)
      return
    case 'board':
      hydrateBoardSnapshot(payload as DashboardMemoryResponse)
      return
    case 'goals': {
      if (!payload || typeof payload !== 'object') return
      const record = payload as { planning?: unknown; tree?: unknown }
      if (record.planning) {
        hydratePlanningSnapshot(record.planning as DashboardPlanningResponse)
      }
      if (record.tree) {
        hydrateGoalTreeSnapshot(record.tree)
      }
      return
    }
    case 'composite':
      hydrateFleetCompositeSnapshot(payload)
      return
  }
}

// --- SSE reaction setup ---

export function setupSSEReaction(): () => void {
  // Watch for reconnections (false -> true transitions)
  const unsubReconnect = reconnectCount.subscribe(() => {
    if (connected.value) {
      handleReconnect()
    }
  })

  const unsubscribe = lastEvent.subscribe((event) => {
    if (!event) return
    routeServerPushEvent(event)
  })

  return () => {
    unsubscribe()
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
    if (!connected.value) {
      invalidateDashboardCache()
    }
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

/** Cancel all pending SSE-triggered refresh timers.
 *  Call on route change to prevent stale fetches from firing after the user
 *  navigates to a different tab. */
export function cancelPendingSSERefreshes(): void {
  for (const key of Object.keys(_debounceTimers)) {
    clearTimeout(_debounceTimers[key])
    delete _debounceTimers[key]
  }
}
