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

// --- Council/CommandPlane/Operator refresh registration (avoids circular import) ---

let _refreshCouncilFn: (() => void) | null = null
export function registerCouncilRefresh(fn: () => void): void {
  _refreshCouncilFn = fn
}

let _refreshCommandPlaneFn: (() => void) | null = null
export function registerCommandPlaneRefresh(fn: () => void): void {
  _refreshCommandPlaneFn = fn
}

let _refreshOperatorFn: (() => void) | null = null
export function registerOperatorRefresh(fn: () => void): void {
  _refreshOperatorFn = fn
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

    // Keeper lifecycle events → execution + mission refresh
    if (
      event.type === 'keeper_handoff'
      || event.type === 'keeper_compaction'
      || event.type === 'keeper_guardrail'
    ) {
      scheduleRefresh('execution', refreshExecution)
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

    // Council events
    if (event.type.startsWith('decision_')) {
      scheduleRefresh('council', () => _refreshCouncilFn?.())
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
  }, 10000)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}
