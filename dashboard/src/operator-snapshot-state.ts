import { computed, signal } from '@preact/signals'
import { dashboardObservationOwnerIsCurrent, readDashboardObservationOwner, type DashboardObservationOwner } from './lib/observation-read-owner'
import type { OperatorSnapshot } from './types'

const snapshot = signal<{ readonly owner: DashboardObservationOwner; readonly value: OperatorSnapshot } | null>(null)

/** Fence retained rows even in the interval before an owner-change effect runs. */
export const operatorSnapshot = computed(() => {
  readDashboardObservationOwner()
  const loaded = snapshot.value
  return loaded !== null && dashboardObservationOwnerIsCurrent(loaded.owner) ? loaded.value : null
})

export function publishOperatorSnapshot(owner: DashboardObservationOwner, value: OperatorSnapshot): void {
  if (dashboardObservationOwnerIsCurrent(owner)) snapshot.value = { owner, value }
}
export function clearOperatorSnapshot(): void { snapshot.value = null }
