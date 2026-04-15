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
import type { BoardPost, DashboardExecutionResponse, SSEEvent } from './types'
import {
  keeperHeartbeats,
  invalidateDashboardCache,
  hydrateExecutionSnapshot,
  refreshExecution,
  refreshBoard,
  serverStatus,
  boardPosts,
  boardSortMode,
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
import { compositeTick } from './composite-signals'
import { hydrateTransportHealthFromSSE } from './components/transport-health'
import { activeKeeperName, hydrateKeeperStatus } from './keeper-runtime'
import { showToast } from './components/common/toast'
import { route } from './router'
import {
  PERIODIC_REFRESH_DEV_MS,
  PERIODIC_REFRESH_PROD_MS,
  SSE_ACTIVITY_DEBOUNCE_MS,
  SSE_DEFAULT_DEBOUNCE_MS,
  SSE_KEEPER_OPERATOR_DEBOUNCE_MS,
  SSE_KEEPER_THREAD_DEBOUNCE_MS,
  SSE_RECONNECT_RETRY_MS,
} from './config/constants'
import { replayOasRuntimeTelemetry } from './oas-runtime-store'

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

const _refreshActivityFns = new Set<() => void>()
export function registerActivityRefresh(fn: () => void): () => void {
  _refreshActivityFns.add(fn)
  return () => {
    _refreshActivityFns.delete(fn)
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
  execution: () => { void refreshExecution({ force: true }) },
  board:     refreshBoard,
  operator:  () => _refreshOperatorFn?.(),
  activity:  () => {
    for (const fn of _refreshActivityFns) fn()
  },
}

// --- Named handlers for complex events ---

const KEEPER_LIFECYCLE_EVENTS = new Set([
  'keeper_handoff', 'keeper_compaction', 'keeper_turn_complete', 'keeper_phase_changed',
  'masc/keeper_handoff', 'masc/keeper_compaction', 'masc/keeper_turn_complete',
])

const AUTORESEARCH_EVENTS = new Set([
  'autoresearch_cycle',
  'autoresearch_started',
  'autoresearch_stopped',
])

/** Hydrate namespace-truth signals directly from SSE payload — zero HTTP fetch. */
function handleNamespaceTruthSnapshot(payload: unknown): void {
  try {
    const normalized = normalizeNamespaceTruth(payload)
    namespaceTruth.value = normalized
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.root.status ?? null,
    )
  } catch (err) {
    console.debug('[SSE] namespace-truth snapshot hydration failed, will fallback to HTTP', err instanceof Error ? err.message : '')
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

function handleTransportHealth(payload: unknown): void {
  try {
    hydrateTransportHealthFromSSE(payload)
  } catch (err) {
    console.debug('[SSE] transport health hydration failed', err instanceof Error ? err.message : '')
  }
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
  // All keeper lifecycle events trigger operator refresh
  scheduleRefresh('operator', () => _refreshOperatorFn?.(), SSE_KEEPER_OPERATOR_DEBOUNCE_MS)

  // keeper_turn_complete: re-hydrate active keeper's conversation + trajectory
  if (event.type === 'keeper_turn_complete') {
    const keeperName = event.name ?? ''
    const viewing = activeKeeperName.value
    if (keeperName && keeperName === viewing) {
      scheduleRefresh(`keeper_thread_${keeperName}`, () => {
        void hydrateKeeperStatus(keeperName, true)
      }, SSE_KEEPER_THREAD_DEBOUNCE_MS)
      scheduleRefresh(`keeper_trajectory_${keeperName}`, async () => {
        const { loadTrajectory } = await import('./components/keeper-trajectory-timeline')
        void loadTrajectory(keeperName)
      }, SSE_KEEPER_THREAD_DEBOUNCE_MS)
    }
  }
}

async function handleGovernance(): Promise<void> {
  _refreshGovernanceFn?.()
  const { loadRuntimeParams } = await import('./components/governance')
  loadRuntimeParams()
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
    await replayOasRuntimeTelemetry()
  } catch (err) {
    console.warn('[SSE] reconnect OAS replay failed', err instanceof Error ? err.message : err)
  }
  requestNamespaceTruthNow()
  void refreshActiveRoute().catch(err =>
    console.warn('[SSE] reconnect route refresh failed', err instanceof Error ? err.message : err),
  )
  // Safety-net retry: if namespace-truth fetch failed (e.g. server warm-up),
  // the scheduler's error signal will be set. Retry once after delay.
  setTimeout(() => {
    if (namespaceTruthError.value) {
      requestNamespaceTruthNow()
    }
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

  const now = new Date().toISOString()
  const post: BoardPost = {
    id: postId,
    author: event.author ?? '',
    title: event.title ?? '',
    body: content,
    content,
    tags: [],
    created_at: now,
    updated_at: now,
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    hearth: event.hearth ?? undefined,
  }
  boardPosts.value = [post, ...boardPosts.value]
  boardOffset.value = boardPosts.value.length
  return true
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

    // 0. Namespace-truth snapshot — server push, no HTTP fetch needed
    if ((event.type === 'namespace_truth_snapshot' || event.type === 'room_truth_snapshot') && event.payload) {
      handleNamespaceTruthSnapshot(event.payload)
      return
    }

    // 0b. Execution snapshot — server push, no HTTP fetch needed
    if (event.type === 'execution_snapshot' && event.payload) {
      handleExecutionSnapshot(event.payload)
      return
    }

    // 0c. Operator/transport snapshots — server push, no HTTP fetch needed
    if (event.type === 'operator_snapshot' && event.payload) {
      handleOperatorSnapshot(event.payload)
      return
    }
    if (event.type === 'operator_digest' && event.payload) {
      handleOperatorDigest(event.payload)
      return
    }
    if (event.type === 'transport_health_snapshot' && event.payload) {
      handleTransportHealth(event.payload)
      return
    }

    // 1. Keeper heartbeat — signal-only, zero network calls
    if (event.type === 'keeper_heartbeat') {
      handleKeeperHeartbeat(event)
      return
    }

    // Composite lifecycle tick — signal-only; consumers (FSM Hub) re-fetch
    // /composite themselves. Envelope carries {name, ts_unix} per RFC-0003.
    if (event.type === 'keeper_composite_changed') {
      const payload = event as unknown as { name?: string; ts_unix?: number }
      const name = typeof payload.name === 'string' ? payload.name : ''
      const ts_unix = typeof payload.ts_unix === 'number' ? payload.ts_unix : Date.now() / 1000
      compositeTick.value = { name, ts_unix }
      return
    }

    // 1b. Board post incremental hydration — when enriched payload is
    // available and sort=recent, prepend directly and skip the full refresh.
    if (event.type === 'post_created' && handleBoardPostCreated(event)) {
      // Hydrated from SSE payload — no HTTP fetch needed.
      return
    }

    // 2. Simple route: exact match
    const simpleRoute = SIMPLE_ROUTES[event.type]
    if (simpleRoute) {
      scheduleRefresh(
        simpleRoute.target,
        REFRESH_FNS[simpleRoute.target],
        simpleRoute.debounceMs,
      )
    }

    // 4. Simple route: prefix match
    for (const { prefix, target } of PREFIX_ROUTES) {
      if (event.type.startsWith(prefix)) {
        scheduleRefresh(target, REFRESH_FNS[target])
        break
      }
    }

    // 5. Keeper lifecycle — additional operator refresh + thread hydration
    if (KEEPER_LIFECYCLE_EVENTS.has(event.type)) {
      handleKeeperLifecycle(event)
    }

    if (AUTORESEARCH_EVENTS.has(event.type) && activeAutoresearchRoute()) {
      scheduleRefresh('autoresearch_route', () => {
        void refreshActiveRoute()
      }, SSE_DEFAULT_DEBOUNCE_MS)
    }

    // 6. Governance events
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
