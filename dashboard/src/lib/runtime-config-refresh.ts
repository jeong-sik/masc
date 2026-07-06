import { refreshKeeperRuntimeStatus } from '../store'
import { reloadRuntimeCatalog } from './runtime-catalog-resource'

export async function refreshRuntimeConfigConsumers(): Promise<void> {
  await Promise.all([
    reloadRuntimeCatalog(),
    refreshKeeperRuntimeStatus({ force: true }),
  ])
}
