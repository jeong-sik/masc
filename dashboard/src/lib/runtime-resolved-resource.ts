// Shared runtime-resolved resource.
//
// GET /api/v1/runtime/resolved carries the fleet-wide keeper/runtime
// assignment truth (explicit [runtime.assignments] entries plus keepers
// riding [runtime].default — see dashboard/src/api/schemas/runtime-resolved.ts).
// The keeper runtime card needs only the assignment_source for the one keeper
// it renders; a module-level resource avoids a per-card fetch of the same
// fleet-wide document.

import { createAsyncResource } from './async-state'
import { fetchRuntimeResolved, type RuntimeResolvedResponse } from '../api/dashboard'

const runtimeResolvedResource = createAsyncResource<RuntimeResolvedResponse>()
export const runtimeResolvedState = runtimeResolvedResource.state

export function loadRuntimeResolved(): void {
  if (runtimeResolvedState.value.status !== 'idle') return
  void runtimeResolvedResource.load(fetchRuntimeResolved)
}

export function resetRuntimeResolved(): void {
  runtimeResolvedResource.reset()
}
