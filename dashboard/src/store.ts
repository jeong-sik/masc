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
  PerpetualStatus,
  TrpgState,
  BoardSortMode,
} from './types'
import { fetchDashboard, fetchBoard, fetchTrpgState } from './api'
import { lastEvent } from './sse'

// --- Core state signals ---

export const agents = signal<Agent[]>([])
export const tasks = signal<Task[]>([])
export const messages = signal<Message[]>([])
export const keepers = signal<Keeper[]>([])
export const serverStatus = signal<ServerStatus | null>(null)
export const perpetualStatus = signal<PerpetualStatus | null>(null)

// --- Board state ---

export const boardPosts = signal<BoardPost[]>([])
export const boardSortMode = signal<BoardSortMode>('hot')

// --- TRPG state ---

export const trpgState = signal<TrpgState | null>(null)
export const trpgRoom = signal<string>('')

// --- Loading flags ---

export const dashboardLoading = signal(false)
export const boardLoading = signal(false)
export const trpgLoading = signal(false)

// --- Derived state ---

export const activeAgents: ReadonlySignal<Agent[]> = computed(() =>
  agents.value.filter(a => a.status === 'active' || a.status === 'idle')
)

export const tasksByStatus = computed(() => {
  const all = tasks.value
  return {
    todo: all.filter(t => t.status === 'todo'),
    inProgress: all.filter(t => t.status === 'in_progress' || t.status === 'claimed'),
    done: all.filter(t => t.status === 'done'),
  }
})

// --- Cache for dashboard batch ---

let _dashboardCache: { data: unknown; time: number } | null = null
const DASHBOARD_CACHE_TTL = 5000

export function invalidateDashboardCache(): void {
  _dashboardCache = null
}

// --- Data fetchers ---

function normalizeKeepers(raw: Keeper[] | { keepers: Keeper[] }): Keeper[] {
  if (Array.isArray(raw)) return raw
  if (raw && Array.isArray(raw.keepers)) return raw.keepers
  return []
}

export async function refreshDashboard(): Promise<void> {
  const now = Date.now()
  if (_dashboardCache && (now - _dashboardCache.time) < DASHBOARD_CACHE_TTL) {
    return // Use cached data (already applied to signals)
  }

  dashboardLoading.value = true
  try {
    const data = await fetchDashboard()
    _dashboardCache = { data, time: now }

    agents.value = data.agents?.agents ?? []
    tasks.value = data.tasks?.tasks ?? []
    messages.value = data.messages?.messages ?? []
    keepers.value = normalizeKeepers(data.keepers)
    serverStatus.value = data.status ?? null
    perpetualStatus.value = data.perpetual ?? null
  } catch (err) {
    console.error('Dashboard fetch error:', err)
  } finally {
    dashboardLoading.value = false
  }
}

export async function refreshBoard(): Promise<void> {
  boardLoading.value = true
  try {
    const data = await fetchBoard()
    boardPosts.value = data.posts ?? []
  } catch (err) {
    console.error('Board fetch error:', err)
  } finally {
    boardLoading.value = false
  }
}

export async function refreshTrpg(): Promise<void> {
  trpgLoading.value = true
  try {
    const room = trpgRoom.value || serverStatus.value?.room || 'default'
    if (!trpgRoom.value) trpgRoom.value = room
    const data = await fetchTrpgState(room)
    trpgState.value = data
  } catch (err) {
    console.error('TRPG fetch error:', err)
  } finally {
    trpgLoading.value = false
  }
}

// --- SSE event reaction ---
// When lastEvent changes, invalidate cache and re-fetch

let _fetchDebounce: ReturnType<typeof setTimeout> | null = null
let _boardDebounce: ReturnType<typeof setTimeout> | null = null

export function setupSSEReaction(): () => void {
  // Subscribe to SSE events and trigger refreshes
  const unsubscribe = lastEvent.subscribe((event) => {
    if (!event) return

    invalidateDashboardCache()

    // Debounced dashboard refresh
    if (!_fetchDebounce) {
      _fetchDebounce = setTimeout(() => {
        refreshDashboard()
        _fetchDebounce = null
      }, 500)
    }

    // Board-specific events trigger board refresh
    if (event.type === 'board_post' || event.type === 'board_comment') {
      if (!_boardDebounce) {
        _boardDebounce = setTimeout(() => {
          refreshBoard()
          _boardDebounce = null
        }, 500)
      }
    }
  })

  return unsubscribe
}

// --- Periodic refresh (for keeper presence heartbeats that don't emit SSE) ---

let _periodicId: ReturnType<typeof setInterval> | null = null

export function startPeriodicRefresh(): void {
  if (_periodicId) return
  _periodicId = setInterval(() => {
    invalidateDashboardCache()
    refreshDashboard()
  }, 10000)
}

export function stopPeriodicRefresh(): void {
  if (_periodicId) {
    clearInterval(_periodicId)
    _periodicId = null
  }
}
