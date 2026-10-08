import { signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

// Runtime publishes Browser activity during the file save. Re-read inventory
// after its receipt, without interpreting that receipt as executor readiness.
const observation = signal<{ authority: ExecutionWorkspaceAuthority; revision: number } | null>(null)

export function announceBrowserLaneObservationChanged(authority: ExecutionWorkspaceAuthority) {
  if (executionWorkspaceAuthority.peek() !== authority) return
  observation.value = { authority, revision: (observation.peek()?.revision ?? 0) + 1 }
}

export function browserLaneObservationRevision(authority: ExecutionWorkspaceAuthority | null) {
  const current = observation.value
  return current?.authority === authority ? current.revision : 0
}
