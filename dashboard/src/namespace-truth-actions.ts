import { fetchDashboardNamespaceTruth } from './api/dashboard-hot'
import { hydrateShellRootSnapshot } from './store'
import {
  namespaceTruth,
  namespaceTruthLoading,
  namespaceTruthError,
  namespaceTruthReadRecovery,
} from './namespace-truth-signals'
import { hydrateNamespaceTruthObservation } from './namespace-truth-observation'
import { FetchScheduler } from './lib/fetch-scheduler'
import { ApiRequestError, captureDashboardCredentialOwner, dashboardCredentialOwnerIsCurrent } from './api/core'

export { WARM_RETRY_DELAYS_MS, WARM_RETRY_CAP_MS, warmRetryDelayFor } from './lib/warm-retry'

// --- Core fetch function (owns signal updates) ---

async function doFetchNamespaceTruth(): Promise<void> {
  namespaceTruthReadRecovery.started()
  const revision = namespaceTruthReadRecovery.revision
  const owner = captureDashboardCredentialOwner()
  const current = () => namespaceTruthReadRecovery.revision === revision && dashboardCredentialOwnerIsCurrent(owner)
  namespaceTruthLoading.value = true
  namespaceTruthError.value = null
  try {
    const raw = await fetchDashboardNamespaceTruth()
    if (!current()) return
    const normalized = hydrateNamespaceTruthObservation(raw, 'http')
    if (normalized !== null) hydrateShellRootSnapshot(normalized.root, true)
  } catch (err) {
    if (!current()) return
    const detail = err instanceof Error ? err.message : 'Failed to load project snapshot'
    console.warn('[project-snapshot] fetch failed:', detail)
    namespaceTruth.value = null
    namespaceTruthError.value = detail
    namespaceTruthReadRecovery.failed(() => { void namespaceTruthScheduler.requestNow() },
      !(err instanceof ApiRequestError && (err.status === 401 || err.status === 403)))
  } finally {
    namespaceTruthLoading.value = false
  }
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
    await namespaceTruthScheduler.requestNowAndWait()
  } else {
    requestNamespaceTruth()
    if (namespaceTruthScheduler.inflightPromise) {
      await namespaceTruthScheduler.inflightPromise
    }
  }
}

export function disposeNamespaceTruthScheduler(): void {
  namespaceTruthReadRecovery.dispose()
  namespaceTruthScheduler.dispose()
}
