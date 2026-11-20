// Shared scheduled-automation resources.
//
// One owner per page of the projection on the client side, mirroring the
// single owner on the server (Server_dashboard_schedule_projection). Root, the
// Schedule surface, and the Lab FSM panel all read these signals; none of them
// fetches the tool inventory to reach schedule state any more.

import { computed, type ReadonlySignal } from '@preact/signals'
import {
  fetchDashboardScheduledAutomation,
} from '../../api/dashboard-scheduled-automation'
import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationProjection,
} from '../../api/dashboard'
import { createManagedAsyncResource } from '../../lib/async-state'
import { setupObservationRefresh } from '../../lib/observation-refresh'

interface ScheduleReader {
  readonly projection: ReadonlySignal<DashboardScheduledAutomationProjection | null>
  readonly error: ReadonlySignal<string | null>
  readonly loading: ReadonlySignal<boolean>
  load(options?: { fresh?: boolean }): Promise<void>
  /** Share one schedule observation across mounted surfaces. */
  subscribe(): () => void
}

/** One page of the schedule projection and the one observation that keeps it
 *  current, whichever surfaces mount it. */
function createScheduleReader(
  read: (signal: AbortSignal) => Promise<DashboardScheduledAutomationProjection>,
): ScheduleReader {
  // Managed (stale-while-revalidate) for the same reason tool-state is: the
  // surfaces re-read on every scheduled_automation observation, and a plain
  // resource would blank the projection on each re-read. The load wrapper below adds single-flight
  // semantics so a slow read retains the last snapshot until the next committed change.
  const resource = createManagedAsyncResource<DashboardScheduledAutomationProjection>()

  let loadInFlight: Promise<void> | null = null
  let freshLoadQueued: Promise<void> | null = null

  function load({ fresh = false }: { fresh?: boolean } = {}): Promise<void> {
    if (loadInFlight) {
      if (!fresh) return loadInFlight
      if (freshLoadQueued) return freshLoadQueued

      const queued: Promise<void> = loadInFlight
        .catch(() => undefined)
        .then(() => freshLoadQueued === queued ? load() : undefined)
        .finally(() => {
          if (freshLoadQueued === queued) freshLoadQueued = null
        })
      freshLoadQueued = queued
      return queued
    }

    let request: Promise<void>
    request = resource
      .load(signal => read(signal))
      .then(() => undefined)
      .finally(() => {
        if (loadInFlight === request) loadInFlight = null
      })
    loadInFlight = request
    return request
  }

  function cancelRead(): void {
    resource.cancel()
    loadInFlight = null
    freshLoadQueued = null
  }

  let subscriberCount = 0
  let stopRefresh: (() => void) | null = null

  function subscribe(): () => void {
    subscriberCount += 1
    if (subscriberCount === 1) {
      stopRefresh = setupObservationRefresh(() => load(), { topics: ['scheduled_automation'], readError: () => resource.readError(), cancelRead, resetRead: () => { cancelRead(); resource.reset() } })
    }
    return () => {
      subscriberCount -= 1
      if (subscriberCount === 0) {
        stopRefresh?.()
        stopRefresh = null
        // Nothing keeps the page current from here on, so it is not held. A
        // surface that mounts later draws once before its subscription
        // starts, and would draw a page kept here as the current one.
        cancelRead()
        resource.reset()
      }
    }
  }

  return {
    projection: computed(() => resource.state.value.data),
    error: computed(() => resource.state.value.error),
    loading: computed(() => resource.state.value.loading),
    load,
    subscribe,
  }
}

// The fleet page: the 20 soonest schedules, with the counts of the whole ledger.
const fleetSchedules = createScheduleReader(
  signal => fetchDashboardScheduledAutomation({ signal }),
)

export const scheduledAutomationProjection = fleetSchedules.projection

/** Available ledger data only. An unavailable projection deliberately appears
 *  as null here so legacy detail panels cannot totalize its placeholder rows. */
export const scheduledAutomation = computed<DashboardScheduledAutomation | null>(
  () => {
    const projection = scheduledAutomationProjection.value
    return projection?.state === 'available' ? projection.data : null
  },
)
export const scheduledAutomationError = fleetSchedules.error
export const scheduledAutomationLoading = fleetSchedules.loading
export const loadScheduledAutomation = fleetSchedules.load
export const subscribeScheduledAutomationRefresh = fleetSchedules.subscribe

// Every schedule that is still going to run, for the calendar (#52961). The
// fleet page stops at the 20 soonest, and polling schedules alone can take all
// of them; this page leaves ended schedules out and holds up to the server's
// selected-page limit. Only the calendar mounts it, so only an open calendar
// reads it.
const activeSchedules = createScheduleReader(
  signal => fetchDashboardScheduledAutomation({ signal, activeOnly: true }),
)

export const activeSchedulesProjection = activeSchedules.projection
export const activeSchedulesError = activeSchedules.error
export const subscribeActiveSchedulesRefresh = activeSchedules.subscribe
