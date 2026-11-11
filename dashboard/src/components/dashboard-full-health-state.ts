import { computed } from '@preact/signals'
import { fetchDashboardFullHealth, type DashboardFullHealthResponse } from '../api/dashboard'
import { createManagedAsyncResource } from '../lib/async-state'
import { setupObservationRefresh } from '../lib/observation-refresh'

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

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

/** Share one health observation between global chrome and Overview. */
export function subscribeDashboardFullHealthRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    stopRefresh = setupObservationRefresh(loadDashboardFullHealth, { topics: ['health'], readError: () => dashboardFullHealthResource.readError(), cancelRead: () => dashboardFullHealthResource.cancel(), resetRead: () => dashboardFullHealthResource.reset() })
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
