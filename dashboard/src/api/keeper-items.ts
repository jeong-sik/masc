import { apiRequestErrorFromResponse, authHeaders, fetchWithTimeout } from './core'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import { parseKeeperItems, type KeeperItemsReading } from './schemas/keeper-items'

export { parseKeeperItems, type KeeperItemsReading } from './schemas/keeper-items'

export async function fetchKeeperItems(keeper: string, signal?: AbortSignal): Promise<KeeperItemsReading> {
  const path = `/api/v1/keepers/${encodeURIComponent(keeper)}/items`
  return fetchWithTimeout(path, { headers: authHeaders(), signal, cache: 'no-cache' }, DEFAULT_GET_TIMEOUT_MS, async response => {
    if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
    return parseKeeperItems(await response.json(), keeper)
  })
}
