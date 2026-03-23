// SSE event reaction and periodic refresh — extracted from store.ts
// Routes SSE events to the minimal refresh function needed.
//
// Event routing uses a declarative map for simple refresh-only events,
// and named handlers for events with custom logic (conditional hydration,
// async imports, signal-only updates).

import { lastEvent, connected, reconnectCount, lastDisconnectedAt } from './sse'
import {
  keeperHeartbeats,
  invalidateDashboardCache,
  isDashboardRefreshEvent,
  refreshDashboard,
  refreshExecution,
  refreshBoard,
  refreshMdal,
} from './store'
import { refreshRoomTruth } from './room-truth-store'
import { activeKeeperName, hydrateKeeperStatus } from './keeper-runtime'
import { showToast } from './components/common/toast'

// --- Refresh function registration (avoids circular imports) ---

let _refreshGovernanceFn: (() => void) | null = null
export function registerGovernanceRefresh(fn: () => void): void {
  _refreshGovernanceFn = fn
}

let _refreshCommandPlaneFn: (() => void) | null = null
export function registerCommandPlaneRefresh(fn: () => void): void {
  _refreshCommandPlaneFn = fn
}

let _refreshOperatorFn: (() => void) | null = null
export function registerOperatorRefresh(fn: () => void): void {
  _refreshOperatorFn = fn
}

let _refreshMissionFn: (() => void) | null = null
export function registerMissionRefresh(fn: () => void): void {
  _refreshMissionFn = fn
}

// --- Debounced scheduling ---

const _debounceTimers: Record<string, ReturnType<typeof setTimeout>> = {}
let _fetchDebounce: ReturnType<typeof setTimeout> | null = null

function scheduleRefresh(key: string, fn: () => void, delayMs = 500): void {
  if (_debounceTimers[key]) clearTimeout(_debounceTimers[key])
  _debounceTimers[key] = setTimeout(() => {
    fn()
    delete _debounceTimers[key]
  }, delayMs)
}

// --- Declarative event routing ---
// Simple events that map directly to a debounced refresh target.
// Complex events (conditional logic, async imports) use named handlers below.

type RefreshTarget = 'execution' | 'board' | 'mdal' | 'operator'

interface SimpleRoute {
  target: RefreshTarget
  debounceMs?: number
}

const SIMPLE_ROUTES: Record<string, SimpleRoute> = {
  // Agent lifecycle (server may emit with or without "masc/" prefix)
  agent_joined:          { target: 'execution' },
  'masc/agent_joined':   { target: 'execution' },
  agent_left:            { target: 'execution' },
  'masc/agent_left':     { target: 'execution' },
  // Broadcasts
  broadcast:             { target: 'execution' },
  'masc/broadcast':      { target: 'execution' },
  // Keeper lifecycle (also triggers operator refresh via handler)
  keeper_handoff:        { target: 'execution' },
  keeper_compaction:     { target: 'execution' },
  keeper_guardrail:      { target: 'execution' },
  // Client input
  client_input_approved:  { target: 'operator', debounceMs: 300 },
  client_input_rejected:  { target: 'operator', debounceMs: 300 },
  client_input_updated:   { target: 'operator', debounceMs: 300 },
  // Board
  board_post:           { target: 'board' },
  'masc/board_post':    { target: 'board' },
  board_comment:        { target: 'board' },
  'masc/board_comment': { target: 'board' },
  // MDAL
  mdal_started:    { target: 'mdal', debounceMs: 350 },
  mdal_iteration:  { target: 'mdal', debounceMs: 350 },
  mdal_completed:  { target: 'mdal', debounceMs: 350 },
  mdal_stopped:    { target: 'mdal', debounceMs: 350 },
}

// Prefix patterns for events that use startsWith matching
const PREFIX_ROUTES: Array<{ prefix: string; target: RefreshTarget }> = [
  { prefix: 'task_',      target: 'execution' },
  { prefix: 'masc/task_', target: 'execution' },
]

const REFRESH_FNS: Record<RefreshTarget, () => void> = {
  execution: () => { void refreshExecution({ force: true }) },
  board:     refreshBoard,
  mdal:      refreshMdal,
  operator:  () => _refreshOperatorFn?.(),
}

// --- Named handlers for complex events ---

const KEEPER_LIFECYCLE_EVENTS = new Set([
  'keeper_handoff', 'keeper_compaction', 'keeper_guardrail', 'keeper_turn_complete',
  'masc/keeper_handoff', 'masc/keeper_compaction', 'masc/keeper_guardrail', 'masc/keeper_turn_complete',
])

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
  scheduleRefresh('operator', () => _refreshOperatorFn?.(), 600)

  // keeper_turn_complete: re-hydrate active keeper's conversation thread
  if (event.type === 'keeper_turn_complete') {
    const keeperName = event.name ?? ''
    const viewing = activeKeeperName.value
    if (keeperName && keeperName === viewing) {
      scheduleRefresh(`keeper_thread_${keeperName}`, () => {
        void hydrateKeeperStatus(keeperName, true)
      }, 800)
    }
  }
}

function handleDashboardRefresh(): void {
  invalidateDashboardCache()
  if (!_fetchDebounce) {
    _fetchDebounce = setTimeout(() => {
      void refreshDashboard({ force: true })
      _refreshCommandPlaneFn?.()
      _refreshOperatorFn?.()
      _fetchDebounce = null
    }, 500)
  }
}

async function handleGovernance(): Promise<void> {
  _refreshGovernanceFn?.()
  const { loadRuntimeParams } = await import('./components/governance')
  loadRuntimeParams()
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
  void hydrateAfterReconnect()
}

async function hydrateAfterReconnect(): Promise<void> {
  try {
    await Promise.all([
      refreshRoomTruth({ force: true }),
      refreshDashboard({ force: true }),
      refreshExecution({ force: true }),
      refreshBoard(),
    ])
    _refreshCommandPlaneFn?.()
    _refreshOperatorFn?.()
    _refreshMissionFn?.()
  } catch {
    // First attempt failed (server may still be warming up) — retry once.
    setTimeout(() => {
      void refreshRoomTruth({ force: true })
      void refreshDashboard({ force: true })
      void refreshExecution({ force: true })
      _refreshOperatorFn?.()
    }, 3000)
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

    // 1. Keeper heartbeat — signal-only, zero network calls
    if (event.type === 'keeper_heartbeat') {
      handleKeeperHeartbeat(event)
      return
    }

    // 2. Dashboard-wide data events — debounced full refresh
    if (isDashboardRefreshEvent(event.type)) {
      handleDashboardRefresh()
    }

    // 3. Simple route: exact match
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

    // 6. Governance events
    if (event.type.startsWith('decision_') || event.type === 'governance_param_changed') {
      scheduleRefresh('governance', () => void handleGovernance())
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

const PERIODIC_REFRESH_MS =
  typeof import.meta !== 'undefined'
    && Boolean((import.meta as unknown as { env?: { DEV?: unknown } }).env?.DEV)
    ? 90_000
    : 30_000

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    if (!connected.value) {
      invalidateDashboardCache()
    }
    void refreshDashboard()
    _refreshMissionFn?.()
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
  if (_fetchDebounce) {
    clearTimeout(_fetchDebounce)
    _fetchDebounce = null
  }
}
