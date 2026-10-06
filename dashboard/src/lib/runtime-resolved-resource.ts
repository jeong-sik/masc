// Shared runtime-resolved resource.
//
// GET /api/v1/runtime/resolved carries the fleet-wide keeper/runtime
// assignment truth (explicit [runtime.assignments] entries plus keepers
// riding [runtime].default — see dashboard/src/api/schemas/runtime-resolved.ts).
// The keeper runtime card needs only the assignment_source for the one keeper
// it renders; a module-level resource avoids a per-card fetch of the same
// fleet-wide document.

import { createRuntimeWorkspaceResource } from './runtime-workspace-resource'
import { fetchRuntimeResolved, type RuntimeResolvedResponse } from '../api/dashboard'

const runtimeResolvedResource = createRuntimeWorkspaceResource<RuntimeResolvedResponse>(signal => fetchRuntimeResolved({ signal }))
export const runtimeResolvedState = runtimeResolvedResource.state

export function loadRuntimeResolved(): Promise<void> {
  return runtimeResolvedResource.load()
}

export function resetRuntimeResolved(): void {
  runtimeResolvedResource.reset()
}

export async function reloadRuntimeResolved(): Promise<void> {
  await runtimeResolvedResource.reload()
}
