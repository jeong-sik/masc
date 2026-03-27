import { fetchDashboardRoomTruth } from './api'
import { asString, isRecord } from './components/common/normalize'
import { serverStatus } from './store'
import {
  roomTruth,
  roomTruthLoading,
  roomTruthError,
  roomTruthInitializing,
} from './room-truth-signals'
import { normalizeRoomTruth } from './room-truth-normalizers'
import { mergeServerStatus } from './store-normalizers'
import { FetchScheduler } from './lib/fetch-scheduler'

// --- Warm-up retry state ---

const WARM_RETRY_DELAY_MS = 3_000
const WARM_MAX_RETRIES = 10
let warmRetryAttempt = 0
let warmRetryTimer: ReturnType<typeof setTimeout> | null = null

// --- Core fetch function (owns signal updates) ---

async function doFetchRoomTruth(): Promise<void> {
  roomTruthLoading.value = true
  roomTruthError.value = null
  try {
    const raw = await fetchDashboardRoomTruth()
    const isInitializing =
      isRecord(raw)
      && asString((raw as Record<string, unknown>).status) === 'initializing'
    if (isInitializing) {
      console.debug('[room-truth] server initializing, scheduling warm-up retry')
      roomTruthInitializing.value = true
      scheduleWarmRetry()
      return
    }
    roomTruthInitializing.value = false
    warmRetryAttempt = 0
    const normalized = normalizeRoomTruth(raw)
    roomTruth.value = normalized
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.room.status ?? null,
    )
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'Failed to load room truth'
    console.warn('[room-truth] fetch failed:', detail)
    roomTruthError.value = detail
  } finally {
    roomTruthLoading.value = false
  }
}

function scheduleWarmRetry(): void {
  warmRetryAttempt++
  console.debug(`[room-truth] warm-up retry ${warmRetryAttempt}/${WARM_MAX_RETRIES}`)
  if (warmRetryAttempt > WARM_MAX_RETRIES) {
    roomTruthInitializing.value = false
    roomTruthError.value = 'Server warm-up timed out. Try refreshing.'
    roomTruthLoading.value = false
    warmRetryAttempt = 0
    return
  }
  if (warmRetryTimer) clearTimeout(warmRetryTimer)
  warmRetryTimer = setTimeout(() => {
    warmRetryTimer = null
    roomTruthScheduler.requestNow()
  }, WARM_RETRY_DELAY_MS)
}

// --- Scheduler instance ---

export const roomTruthScheduler = new FetchScheduler(doFetchRoomTruth, {
  cooldownMs: 2_000,
  debounceMs: 300,
})

// --- Public API ---

/** Request a room-truth refresh (debounced, cooldown-enforced). */
export function requestRoomTruth(): void {
  roomTruthScheduler.request()
}

/** Request an immediate room-truth refresh (deduped with inflight). */
export function requestRoomTruthNow(): void {
  roomTruthScheduler.requestNow()
}

/**
 * Backward-compatible wrapper. Prefer requestRoomTruth() / requestRoomTruthNow().
 *
 * When opts.force is true, delegates to requestNow() and returns a promise
 * that resolves when the inflight fetch completes (for callers that await).
 */
export async function refreshRoomTruth(opts?: { force?: boolean }): Promise<void> {
  if (opts?.force) {
    requestRoomTruthNow()
  } else {
    requestRoomTruth()
  }
  if (roomTruthScheduler.inflightPromise) {
    await roomTruthScheduler.inflightPromise
  }
}

export function disposeRoomTruthScheduler(): void {
  if (warmRetryTimer) {
    clearTimeout(warmRetryTimer)
    warmRetryTimer = null
  }
  warmRetryAttempt = 0
  roomTruthScheduler.dispose()
}
