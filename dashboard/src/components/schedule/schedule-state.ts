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
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'

// Managed (stale-while-revalidate) for the same reason tool-state is: the
// surfaces poll on a timer, and a plain resource would blank the projection on
// every cycle. The schedule-specific load wrapper below adds single-flight
// semantics so a slow request is never aborted by the next polling tick.
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

    freshLoadQueued = loadInFlight
      .catch(() => undefined)
      .then(() => loadScheduledAutomation())
      .finally(() => {
        freshLoadQueued = null
      })
    return freshLoadQueued
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

export const SCHEDULED_AUTOMATION_REFRESH_MS = 15_000

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

/** Share one visibility-aware poller across every mounted surface that shows
 *  schedule state, so two mounted surfaces do not run two timers. */
export function subscribeScheduledAutomationRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    const projection = scheduledAutomationProjection.value
    if (
      (!projection || projection.state === 'unavailable')
      && !scheduledAutomationLoading.value
    ) {
      void loadScheduledAutomation()
    }
    stopRefresh = setupVisibleAutoRefresh(() => {
      void loadScheduledAutomation()
    }, SCHEDULED_AUTOMATION_REFRESH_MS)
  }
  return () => {
    subscriberCount -= 1
    if (subscriberCount === 0) {
      stopRefresh?.()
      stopRefresh = null
    }
  }
}
