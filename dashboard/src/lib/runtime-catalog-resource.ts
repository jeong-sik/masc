// Shared runtime catalog resource.
//
// Several surfaces (keeper runtime editor, keeper workspace rail, runtime health
// monitor) need provider/model capability snapshots. A single module-level
// resource ensures the dashboard fetches `/api/v1/providers` at most once per
// session and shares the result, rather than each component issuing its own
// request.

import { createAsyncResource } from './async-state'
import {
  fetchRuntimeProviders,
  type DashboardRuntimeProviderSnapshot,
} from '../api/dashboard'

const runtimeCatalogResource = createAsyncResource<DashboardRuntimeProviderSnapshot[]>()
export const runtimeCatalogState = runtimeCatalogResource.state

export function loadRuntimeCatalog(): void {
  if (runtimeCatalogState.value.status !== 'idle') return
  void runtimeCatalogResource.load(async () => {
    const response = await fetchRuntimeProviders()
    return response.providers
  })
}

export function resetRuntimeCatalog(): void {
  runtimeCatalogResource.reset()
}

export function reloadRuntimeCatalog(): void {
  runtimeCatalogResource.reset()
  loadRuntimeCatalog()
}

export function findRuntimeCatalogEntry(
  catalog: readonly DashboardRuntimeProviderSnapshot[],
  runtimeId: string,
): DashboardRuntimeProviderSnapshot | null {
  const needle = runtimeId.trim()
  if (needle === '') return null
  return (
    catalog.find(item => {
      const ids = [item.runtime_id, item.provider]
      return ids.some(id => id?.trim() === needle)
    }) ?? null
  )
}
