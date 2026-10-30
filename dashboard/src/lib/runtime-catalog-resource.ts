// Shared runtime catalog resource.
//
// Several surfaces (keeper runtime editor, keeper workspace rail, runtime health
// monitor) need provider/model capability snapshots. A single module-level
// resource shares one reading for the current workspace. Workspace changes
// invalidate the old reading and refresh existing consumers automatically.

import { type AsyncState } from './async-state'
import { createRuntimeWorkspaceResource } from './runtime-workspace-resource'
import {
  fetchRuntimeProviders,
  type DashboardRuntimeProviderSnapshot,
} from '../api/dashboard'

const runtimeCatalogResource = createRuntimeWorkspaceResource<DashboardRuntimeProviderSnapshot[]>(async signal =>
  (await fetchRuntimeProviders({ signal })).providers)
export const runtimeCatalogState = runtimeCatalogResource.state

export function loadRuntimeCatalog(): void {
  void runtimeCatalogResource.load()
}

export function resetRuntimeCatalog(): void {
  runtimeCatalogResource.reset()
}

export async function reloadRuntimeCatalog(): Promise<void> {
  await runtimeCatalogResource.reload()
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
