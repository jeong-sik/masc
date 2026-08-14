import { computed } from '@preact/signals'
import { fetchDashboardFullHealth, type DashboardFullHealthResponse } from '../api/dashboard'
import { createManagedAsyncResource } from '../lib/async-state'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

export const dashboardFullHealthResource = createManagedAsyncResource<DashboardFullHealthResponse>()

export const dashboardFullHealth = computed(() => {
  const state = dashboardFullHealthResource.state.value
  return state.data
})

export function loadDashboardFullHealth(): Promise<void> {
  return dashboardFullHealthResource
    .load(signal => fetchDashboardFullHealth({ signal }))
    .then(() => undefined)
}

export const DASHBOARD_FULL_HEALTH_REFRESH_MS = 60_000

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

/** Share one visibility-aware /health poller between global chrome and Overview. */
export function subscribeDashboardFullHealthRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    void loadDashboardFullHealth()
    stopRefresh = setupVisibleAutoRefresh(() => {
      void loadDashboardFullHealth()
    }, DASHBOARD_FULL_HEALTH_REFRESH_MS)
  }
  return () => {
    subscriberCount -= 1
    if (subscriberCount === 0) {
      stopRefresh?.()
      stopRefresh = null
      dashboardFullHealthResource.cancel()
    }
  }
}
