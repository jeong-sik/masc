import { signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

// Applying a saved file can publish the registry later than the file receipt.
// The notification outlives components, without changing any editor's draft or
// announcing a second file write. Old connection completions cannot publish it.
const observation = signal<{ authority: ExecutionWorkspaceAuthority; revision: number } | null>(null)

export function announceExactLaneObservationChanged(authority: ExecutionWorkspaceAuthority) {
  if (executionWorkspaceAuthority.peek() !== authority) return
  observation.value = { authority, revision: (observation.peek()?.revision ?? 0) + 1 }
}

export function exactLaneObservationRevision(authority: ExecutionWorkspaceAuthority | null) {
  const current = observation.value
  return current?.authority === authority ? current.revision : 0
}
