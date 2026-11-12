import { signal, type ReadonlySignal } from '@preact/signals'

export interface ExecutionWorkspaceAuthority {
  readonly epoch: string
  readonly workspaceRoot: string
  readonly connectionGeneration: number
  readonly observerInstanceId: string | null
}

// Only the execution hydrator writes this signal. Keeping the same signal in
// this dependency-free module lets readers fence the accepted owner without a
// Store -> observation helper -> Store import cycle.
export const acceptedExecutionWorkspace = signal<ExecutionWorkspaceAuthority | null>(null)
/** Object identity is the admission token: A -> B -> A cannot revive an old read. */
export const executionWorkspaceAuthority: ReadonlySignal<ExecutionWorkspaceAuthority | null>
  = acceptedExecutionWorkspace
