// Shared runtime catalog resource.
//
// Several surfaces (keeper runtime editor, keeper workspace rail, runtime health
// monitor) need provider/model capability snapshots. A single module-level
// resource ensures the dashboard fetches `/api/v1/providers` at most once per
// session and shares the result, rather than each component issuing its own
// request.

import { createAsyncResource, type AsyncState } from './async-state'
import {
  fetchRuntimeProviders,
  type DashboardRuntimeProviderSnapshot,
} from '../api/dashboard'

const runtimeCatalogResource = createAsyncResource<DashboardRuntimeProviderSnapshot[]>()
export const runtimeCatalogState = runtimeCatalogResource.state

async function fetchRuntimeCatalog(): Promise<DashboardRuntimeProviderSnapshot[]> {
  const response = await fetchRuntimeProviders()
  return response.providers
}

export function loadRuntimeCatalog(): void {
  if (runtimeCatalogState.value.status !== 'idle') return
  void runtimeCatalogResource.load(fetchRuntimeCatalog)
}

export function resetRuntimeCatalog(): void {
  runtimeCatalogResource.reset()
}

export async function reloadRuntimeCatalog(): Promise<void> {
  runtimeCatalogResource.reset()
  let loadError: unknown = null
  await runtimeCatalogResource.load(async () => {
    try {
      return await fetchRuntimeCatalog()
    } catch (err) {
      loadError = err
      throw err
    }
  })
  if (loadError) throw loadError
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

export type RuntimeCatalogEntryResolution =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  | { readonly status: 'missing' }
  | { readonly status: 'ready'; readonly entry: DashboardRuntimeProviderSnapshot }

/**
 * Resolve a runtime against the catalog without collapsing transport state into
 * a false "missing" result. `idle` is presented as loading because every
 * consumer calls `loadRuntimeCatalog` when it mounts.
 */
export function resolveRuntimeCatalogEntry(
  state: AsyncState<DashboardRuntimeProviderSnapshot[]>,
  runtimeId: string | null | undefined,
): RuntimeCatalogEntryResolution {
  switch (state.status) {
    case 'idle':
    case 'loading':
      return { status: 'loading' }
    case 'error':
      return { status: 'error', message: state.message }
    case 'loaded': {
      const entry = findRuntimeCatalogEntry(state.data, runtimeId ?? '')
      return entry === null
        ? { status: 'missing' }
        : { status: 'ready', entry }
    }
  }
}
