import { fetchDashboardNamespaceTruth } from './api/dashboard-hot'
import { asString, isRecord } from './components/common/normalize'
import { serverStatus } from './store'
import {
  namespaceTruth,
  namespaceTruthLoading,
  namespaceTruthError,
  namespaceTruthInitializing,
} from './namespace-truth-signals'
import { normalizeNamespaceTruth } from './namespace-truth-normalizers'
import { mergeServerStatus } from './store-normalizers'
import { FetchScheduler } from './lib/fetch-scheduler'

// --- Warm-up retry state ---
//
// Phase 2 Action 6 — exponential backoff replaces the fixed 3 000 ms cadence.
// The fixed cadence kept beating the server at 3 s intervals during cold
// starts, which interacted poorly with Dashboard_cache stampede protection
// (every retry races to start a fresh compute).  The schedule below
// (3 s / 5 s / 10 s / 20 s / cap 30 s) preserves the worst-case warm-up
// budget (WARM_MAX_RETRIES retries) while smoothing client load.

export const WARM_RETRY_DELAYS_MS = [3_000, 5_000, 10_000, 20_000, 30_000]
export const WARM_RETRY_CAP_MS = 30_000

export function warmRetryDelayFor(attempt: number): number {
  // attempt is 1-indexed by callers; clamp to the schedule, falling back
  // to the cap so a misuse never produces 0 / NaN / negative delay.
  if (!Number.isFinite(attempt) || attempt < 1) return WARM_RETRY_DELAYS_MS[0]
  const idx = Math.min(attempt - 1, WARM_RETRY_DELAYS_MS.length - 1)
  const delay = WARM_RETRY_DELAYS_MS[idx]
  return delay ?? WARM_RETRY_CAP_MS
}

const WARM_MAX_RETRIES = 10
let warmRetryAttempt = 0
let warmRetryTimer: ReturnType<typeof setTimeout> | null = null

// --- Core fetch function (owns signal updates) ---

async function doFetchNamespaceTruth(): Promise<void> {
  namespaceTruthLoading.value = true
  namespaceTruthError.value = null
  try {
    const raw = await fetchDashboardNamespaceTruth()
    const isInitializing =
      isRecord(raw)
      && asString((raw as Record<string, unknown>).status) === 'initializing'
    if (isInitializing) {
      console.debug('[project-snapshot] server initializing, scheduling warm-up retry')
      namespaceTruthInitializing.value = true
      scheduleNamespaceWarmRetry()
      return
    }
    namespaceTruthInitializing.value = false
    warmRetryAttempt = 0
    const normalized = normalizeNamespaceTruth(raw)
    namespaceTruth.value = normalized
    serverStatus.value = mergeServerStatus(
      serverStatus.value,
      normalized.root.status ?? null,
    )
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'Failed to load project snapshot'
    console.warn('[project-snapshot] fetch failed:', detail)
    namespaceTruthError.value = detail
  } finally {
    namespaceTruthLoading.value = false
  }
}

function scheduleNamespaceWarmRetry(): void {
  warmRetryAttempt++
  if (warmRetryAttempt > WARM_MAX_RETRIES) {
    namespaceTruthInitializing.value = false
    namespaceTruthError.value = 'Server warm-up timed out. Try refreshing.'
    namespaceTruthLoading.value = false
    warmRetryAttempt = 0
    return
  }
  const delayMs = warmRetryDelayFor(warmRetryAttempt)
  console.debug(
    `[project-snapshot] warm-up retry ${warmRetryAttempt}/${WARM_MAX_RETRIES} in ${delayMs}ms`,
  )
  if (warmRetryTimer) clearTimeout(warmRetryTimer)
  warmRetryTimer = setTimeout(() => {
    warmRetryTimer = null
    namespaceTruthScheduler.requestNow()
  }, delayMs)
}

// --- Scheduler instance ---

const namespaceTruthScheduler = new FetchScheduler(doFetchNamespaceTruth, {
  cooldownMs: 2_000,
  debounceMs: 300,
})

// --- Public API ---

/** Request a project-snapshot refresh (debounced, cooldown-enforced). */
export function requestNamespaceTruth(): void {
  namespaceTruthScheduler.request()
}

/** Request an immediate project-snapshot refresh (deduped with inflight). */
export function requestNamespaceTruthNow(): void {
  namespaceTruthScheduler.requestNow()
}

export async function refreshNamespaceTruth(opts?: { force?: boolean }): Promise<void> {
  if (opts?.force) {
    requestNamespaceTruthNow()
  } else {
    requestNamespaceTruth()
  }
  if (namespaceTruthScheduler.inflightPromise) {
    await namespaceTruthScheduler.inflightPromise
  }
}

export function disposeNamespaceTruthScheduler(): void {
  if (warmRetryTimer) {
    clearTimeout(warmRetryTimer)
    warmRetryTimer = null
  }
  warmRetryAttempt = 0
  namespaceTruthScheduler.dispose()
}
