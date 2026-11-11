// Shared scheduled-automation resource.
//
// One owner for the projection on the client side, mirroring the single owner
// on the server (Server_dashboard_schedule_projection). Root, the Schedule
// surface, and the Lab FSM panel all read this signal; none of them fetches
// the tool inventory to reach schedule state any more.

import { computed } from '@preact/signals'
import {
  fetchDashboardScheduledAutomation,
} from '../../api/dashboard-scheduled-automation'
import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationProjection,
} from '../../api/dashboard'
import { createManagedAsyncResource } from '../../lib/async-state'
import { setupObservationRefresh } from '../../lib/observation-refresh'

// Managed (stale-while-revalidate) for the same reason tool-state is: the
// surfaces poll on a timer, and a plain resource would blank the projection on
// every cycle. The schedule-specific load wrapper below adds single-flight
// semantics so a slow read retains the last snapshot until the next committed change.
const scheduledAutomationResource =
  createManagedAsyncResource<DashboardScheduledAutomationProjection>()

export const scheduledAutomationProjection = computed(
  () => scheduledAutomationResource.state.value.data,
)

/** Available ledger data only. An unavailable projection deliberately appears
 *  as null here so legacy detail panels cannot totalize its placeholder rows. */
export const scheduledAutomation = computed<DashboardScheduledAutomation | null>(
  () => {
    const projection = scheduledAutomationProjection.value
    return projection?.state === 'available' ? projection.data : null
  },
)
export const scheduledAutomationError = computed<string | null>(
  () => scheduledAutomationResource.state.value.error,
)
export const scheduledAutomationLoading = computed(
  () => scheduledAutomationResource.state.value.loading,
)

let loadInFlight: Promise<void> | null = null
let freshLoadQueued: Promise<void> | null = null

export function loadScheduledAutomation(
  { fresh = false }: { fresh?: boolean } = {},
): Promise<void> {
  if (loadInFlight) {
    if (!fresh) return loadInFlight
    if (freshLoadQueued) return freshLoadQueued

    const queued: Promise<void> = loadInFlight
      .catch(() => undefined)
      .then(() => freshLoadQueued === queued ? loadScheduledAutomation() : undefined)
      .finally(() => {
        if (freshLoadQueued === queued) freshLoadQueued = null
      })
    freshLoadQueued = queued
    return queued
  }

  let request: Promise<void>
  request = scheduledAutomationResource
    .load(signal => fetchDashboardScheduledAutomation({ signal }))
    .then(() => undefined)
    .finally(() => {
      if (loadInFlight === request) loadInFlight = null
    })
  loadInFlight = request
  return request
}

function cancelScheduledAutomationRead(): void {
  scheduledAutomationResource.cancel()
  loadInFlight = null
  freshLoadQueued = null
}

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

/** Share one schedule observation across mounted surfaces. */
export function subscribeScheduledAutomationRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    stopRefresh = setupObservationRefresh(() => loadScheduledAutomation(), { topics: ['scheduled_automation'], readError: () => scheduledAutomationResource.readError(), cancelRead: cancelScheduledAutomationRead, resetRead: () => { cancelScheduledAutomationRead(); scheduledAutomationResource.reset() } })
  }
  return () => {
    subscriberCount -= 1
    if (subscriberCount === 0) {
      stopRefresh?.()
      stopRefresh = null
    }
  }
}
