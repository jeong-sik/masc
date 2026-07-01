import { refreshKeeperRuntimeStatus } from '../store'
import { reloadRuntimeCatalog } from './runtime-catalog-resource'

export async function refreshRuntimeConfigConsumers(): Promise<void> {
  reloadRuntimeCatalog()
  await refreshKeeperRuntimeStatus({ force: true })
}
