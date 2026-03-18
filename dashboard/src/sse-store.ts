// SSE event reaction and periodic refresh — extracted from store.ts
// Routes SSE events to the minimal refresh function needed.

import { lastEvent, connected } from './sse'
import {
  keeperHeartbeats,
  invalidateDashboardCache,
  isDashboardRefreshEvent,
  refreshDashboard,
  refreshExecution,
  refreshBoard,
  refreshMdal,
} from './store'
import { activeKeeperName, hydrateKeeperStatus } from './keeper-runtime'

// --- Governance/CommandPlane/Operator refresh registration (avoids circular import) ---

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

// --- SSE event reaction ---

const _debounceTimers: Record<string, ReturnType<typeof setTimeout>> = {}
let _fetchDebounce: ReturnType<typeof setTimeout> | null = null

function scheduleRefresh(key: string, fn: () => void, delayMs = 500): void {
  if (_debounceTimers[key]) clearTimeout(_debounceTimers[key])
  _debounceTimers[key] = setTimeout(() => {
    fn()
    delete _debounceTimers[key]
  }, delayMs)
}

export function setupSSEReaction(): () => void {
  const unsubscribe = lastEvent.subscribe((event) => {
    if (!event) return

    // Keeper heartbeat — update signal directly, zero network calls
    if (event.type === 'keeper_heartbeat' && event.name) {
      const next = new Map(keeperHeartbeats.value)
      next.set(event.name, event.ts_unix ? event.ts_unix * 1000 : Date.now())
      keeperHeartbeats.value = next
      return
    }

    // Agent events → execution surface refresh
    if (event.type === 'agent_joined' || event.type === 'agent_left') {
      scheduleRefresh('execution', refreshExecution)
    }

    // Dashboard data events — debounced full refresh
    if (isDashboardRefreshEvent(event.type)) {
      invalidateDashboardCache()
      if (!_fetchDebounce) {
        _fetchDebounce = setTimeout(() => {
          refreshDashboard()
          _refreshCommandPlaneFn?.()
          _refreshOperatorFn?.()
          _fetchDebounce = null
        }, 500)
      }
    }

    // Task events → execution surface refresh
    if (event.type.startsWith('task_') || event.type.startsWith('masc/task_')) {
      scheduleRefresh('execution', refreshExecution)
    }

    // Broadcast → execution timeline refresh
    if (event.type === 'broadcast') {
      scheduleRefresh('execution', refreshExecution)
    }

    // Keeper lifecycle events → execution + operator refresh
    if (
      event.type === 'keeper_handoff'
      || event.type === 'keeper_compaction'
      || event.type === 'keeper_guardrail'
      || event.type === 'keeper_turn_complete'
    ) {
      scheduleRefresh('execution', refreshExecution)
      scheduleRefresh('operator', () => _refreshOperatorFn?.(), 600)

      // Re-hydrate conversation thread for the active keeper so chat
      // updates without a manual page refresh.
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

    // Client input approval/rejection → operator refresh
    if (
      event.type === 'client_input_approved'
      || event.type === 'client_input_rejected'
      || event.type === 'client_input_updated'
    ) {
      scheduleRefresh('operator', () => _refreshOperatorFn?.(), 300)
    }

    // Board events → board refresh only
    if (
      event.type === 'board_post'
      || event.type === 'masc/board_post'
      || event.type === 'board_comment'
      || event.type === 'masc/board_comment'
    ) {
      scheduleRefresh('board', refreshBoard)
    }

    // Governance events (including param changes from governance enforcement)
    if (event.type.startsWith('decision_') || event.type === 'governance_param_changed') {
      scheduleRefresh('governance', async () => {
        _refreshGovernanceFn?.()
        // Also refresh runtime params panel so it reflects param changes immediately
        const { loadRuntimeParams } = await import('./components/governance')
        loadRuntimeParams()
      })
    }

    // MDAL events
    if (
      event.type === 'mdal_started'
      || event.type === 'mdal_iteration'
      || event.type === 'mdal_completed'
      || event.type === 'mdal_stopped'
    ) {
      scheduleRefresh('mdal', refreshMdal, 350)
    }
  })

  return () => {
    unsubscribe()
    for (const key of Object.keys(_debounceTimers)) {
      clearTimeout(_debounceTimers[key])
      delete _debounceTimers[key]
    }
  }
}

// --- Periodic refresh (for keeper presence heartbeats that don't emit SSE) ---

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    if (!connected.value) {
      invalidateDashboardCache()
    }
    refreshDashboard()
    _refreshMissionFn?.()
  }, 30000)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}

/** Cancel all pending SSE-triggered refresh timers.
 *  Call on route change to prevent stale fetches from firing after the user
 *  navigates to a different tab (fixes C-4/M-12 race condition). */
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
