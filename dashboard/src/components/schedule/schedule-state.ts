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
import type { DashboardScheduledAutomation } from '../../api/dashboard'
import { createManagedAsyncResource } from '../../lib/async-state'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'

// Managed (stale-while-revalidate) for the same reason tool-state is: the
// surfaces poll on a timer, and a plain resource would blank the projection on
// every cycle. This does NOT deduplicate concurrent loads into one in-flight
// request — createAsyncResource does that but drops last-good data. Unifying
// the two is the async-state consolidation, not this change; doing it for this
// one resource would leave the other 38 consumers on the old shape.
const scheduledAutomationResource =
  createManagedAsyncResource<DashboardScheduledAutomation>()

export const scheduledAutomation = computed(
  () => scheduledAutomationResource.state.value.data,
)
export const scheduledAutomationError = computed<string | null>(
  () => scheduledAutomationResource.state.value.error,
)
export const scheduledAutomationLoading = computed(
  () => scheduledAutomationResource.state.value.loading,
)

export async function loadScheduledAutomation(): Promise<void> {
  await scheduledAutomationResource.load(signal =>
    fetchDashboardScheduledAutomation({ signal }),
  )
}

export const SCHEDULED_AUTOMATION_REFRESH_MS = 15_000

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

/** Share one visibility-aware poller across every mounted surface that shows
 *  schedule state, so two mounted surfaces do not run two timers. */
export function subscribeScheduledAutomationRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    if (!scheduledAutomation.value && !scheduledAutomationLoading.value) {
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
