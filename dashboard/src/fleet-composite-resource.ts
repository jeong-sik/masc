import { computed, signal } from '@preact/signals'
import { ApiRequestError } from './api/core'
import { fetchKeepersComposite, type FleetCompositeSnapshot } from './api/keeper'
import { createManagedAsyncResource } from './lib/async-state'
import {
  captureDashboardObservationOwner,
  dashboardObservationOwnerHasWorkspace,
  dashboardObservationOwnerIsCurrent,
  readDashboardObservationOwner,
  type DashboardObservationOwner,
} from './lib/observation-read-owner'
import { publishDashboardObservationChange, setupObservationRefresh } from './lib/observation-refresh'

export interface FleetCompositeObservation {
  readonly owner: DashboardObservationOwner
  readonly value: FleetCompositeSnapshot
}
export interface FleetCompositeLease {
  refresh(keeperName?: string): Promise<FleetCompositeSnapshot>
  release(): void
}
interface Lease { active: boolean }
interface CompletionWaiter {
  readonly lease: Lease
  readonly owner: DashboardObservationOwner
  readonly after: number
  readonly resolve: (value: FleetCompositeSnapshot) => void
  readonly reject: (cause: unknown) => void
}

const resource = createManagedAsyncResource<FleetCompositeObservation>()
const leases = new Set<Lease>()
const waiters = new Set<CompletionWaiter>()
let stop: (() => void) | null = null
let started = 0
let activeReadSignal: AbortSignal | null = null
const active = signal(false)
const retired = () => new DOMException('Fleet composite observation retired', 'AbortError')

export const fleetCompositeObservation = computed<FleetCompositeObservation | null>(() => {
  void readDashboardObservationOwner()
  const state = resource.state.value
  return active.value && state.error === null && state.data !== null
    && dashboardObservationOwnerIsCurrent(state.data.owner) ? state.data : null
})
export const fleetCompositeData = computed(() => fleetCompositeObservation.value?.value ?? null)
export const fleetCompositeLoading = computed(() => {
  const state = resource.state.value
  return active.value && (state.loading || (state.data === null && state.error === null))
})
export const fleetCompositeError = computed(() => active.value ? resource.state.value.error : null)

function rejectWaiters(cause: unknown, matches: (waiter: CompletionWaiter) => boolean): void {
  for (const waiter of waiters) {
    if (!matches(waiter)) continue
    waiters.delete(waiter)
    waiter.reject(cause)
  }
}

async function read(signal: AbortSignal): Promise<void> {
  const sequence = ++started
  activeReadSignal = signal
  const owner = captureDashboardObservationOwner()
  try {
    const loaded = await resource.load(async requestSignal => {
      const value = await fetchKeepersComposite({ signal: AbortSignal.any([signal, requestSignal]) })
      signal.throwIfAborted()
      if (!dashboardObservationOwnerIsCurrent(owner)) throw retired()
      return { owner, value }
    })
    signal.throwIfAborted()
    const failure = resource.readError()
    const refusal = failure instanceof ApiRequestError && (failure.status === 401 || failure.status === 403)
    for (const waiter of waiters) {
      // A terminal refusal stops this owner's owed reads as well; waiting
      // for an inadmissible trailing read would leave its join unresolved.
      if (sequence < waiter.after && !refusal) continue
      waiters.delete(waiter)
      if (!waiter.lease.active || !dashboardObservationOwnerIsCurrent(waiter.owner)) waiter.reject(retired())
      else if (failure !== null) waiter.reject(failure)
      else if (loaded !== undefined) waiter.resolve(loaded.value)
      else waiter.reject(retired())
    }
    if (failure !== null) throw failure
  } finally {
    if (activeReadSignal === signal) activeReadSignal = null
  }
}

/** One fixed query, owned by its mounted consumers. Events and failed-read
 * recovery use the existing helper; leases never own separate HTTP loops. */
export function acquireFleetComposite(): FleetCompositeLease {
  const lease: Lease = { active: true }
  leases.add(lease)
  if (leases.size === 1) {
    active.value = true
    stop = setupObservationRefresh(read, {
      topics: ['keeper_composite'],
      cancelRead: () => {
        resource.cancel()
        rejectWaiters(activeReadSignal?.reason ?? retired(), waiter => !dashboardObservationOwnerIsCurrent(waiter.owner))
      },
      resetRead: () => {
        resource.reset()
        rejectWaiters(activeReadSignal?.reason ?? retired(), waiter => !dashboardObservationOwnerIsCurrent(waiter.owner))
      },
      readError: () => resource.readError(),
    })
  }
  return {
    refresh: keeperName => {
      const owner = captureDashboardObservationOwner()
      if (!lease.active || !dashboardObservationOwnerHasWorkspace(owner)) return Promise.reject(retired())
      const failure = resource.readError()
      if (failure instanceof ApiRequestError && (failure.status === 401 || failure.status === 403)) {
        return Promise.reject(failure)
      }
      return new Promise<FleetCompositeSnapshot>((resolve, reject) => {
        waiters.add({ lease, owner, after: started + 1, resolve, reject })
        // An explicit refresh requests a new observation, including one
        // trailing read when a pre-request read is already in flight.
        publishDashboardObservationChange({ topic: 'keeper_composite', keeperName })
      })
    },
    release: () => {
      if (!lease.active) return
      lease.active = false
      leases.delete(lease)
      if (leases.size === 0) {
        stop?.()
        stop = null
        resource.cancel()
        active.value = false
      }
      rejectWaiters(activeReadSignal?.reason ?? retired(), waiter => waiter.lease === lease)
    },
  }
}
