import { refreshKeeperRuntimeStatus } from '../store'
import { reloadRuntimeCatalog } from './runtime-catalog-resource'
import { reloadRuntimeResolved } from './runtime-resolved-resource'

export async function refreshRuntimeConfigConsumers(): Promise<void> {
  await Promise.all([
    reloadRuntimeCatalog(),
    reloadRuntimeResolved(),
    refreshKeeperRuntimeStatus({ force: true }),
  ])
}
