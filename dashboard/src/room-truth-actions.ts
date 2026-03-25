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

let inflightRoomTruthRefresh: Promise<void> | null = null
let lastRoomTruthRefreshAt = 0
const ROOM_TRUTH_TTL_MS = 60_000

const WARM_RETRY_DELAY_MS = 3_000
const WARM_MAX_RETRIES = 10

export async function refreshRoomTruth(opts?: { force?: boolean }): Promise<void> {
  if (inflightRoomTruthRefresh) return inflightRoomTruthRefresh
  if (!opts?.force && Date.now() - lastRoomTruthRefreshAt < ROOM_TRUTH_TTL_MS) return

  roomTruthLoading.value = true
  roomTruthError.value = null
  inflightRoomTruthRefresh = (async () => {
    try {
      const raw = await fetchDashboardRoomTruth()
      const isInitializing =
        isRecord(raw)
        && asString((raw as Record<string, unknown>).status) === 'initializing'
      if (isInitializing) {
        console.debug('[room-truth] server initializing, scheduling warm-up retry')
        roomTruthInitializing.value = true
        scheduleWarmRetry(1)
        return
      }
      roomTruthInitializing.value = false
      const normalized = normalizeRoomTruth(raw)
      roomTruth.value = normalized
      serverStatus.value = mergeServerStatus(
        serverStatus.value,
        normalized.room.status ?? null,
      )
      lastRoomTruthRefreshAt = Date.now()
    } catch (err) {
      const detail = err instanceof Error ? err.message : 'Failed to load room truth'
      console.warn('[room-truth] fetch failed:', detail)
      roomTruthError.value = detail
    } finally {
      roomTruthLoading.value = false
      inflightRoomTruthRefresh = null
    }
  })()

  return inflightRoomTruthRefresh
}

function scheduleWarmRetry(attempt: number): void {
  console.debug(`[room-truth] warm-up retry ${attempt}/${WARM_MAX_RETRIES}`)
  if (attempt > WARM_MAX_RETRIES) {
    roomTruthInitializing.value = false
    roomTruthError.value = 'Server warm-up timed out. Try refreshing.'
    roomTruthLoading.value = false
    inflightRoomTruthRefresh = null
    return
  }
  window.setTimeout(() => {
    inflightRoomTruthRefresh = null
    void refreshRoomTruth().then(() => {
      if (roomTruthInitializing.value) {
        scheduleWarmRetry(attempt + 1)
      }
    })
  }, WARM_RETRY_DELAY_MS)
}
