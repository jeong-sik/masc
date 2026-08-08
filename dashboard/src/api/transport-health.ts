import { get, type AbortableRequestOptions } from './core'
import {
  parseTransportHealthData,
  type HotSession,
  type TransportHealthData,
} from './schemas/transport-health'

export type { HotSession, TransportHealthData }
export {
  parseTransportHealthData,
  TransportHealthSchemaDriftError,
} from './schemas/transport-health'

export async function fetchTransportHealth(
  opts?: AbortableRequestOptions,
): Promise<TransportHealthData> {
  const raw = await get<unknown>('/api/v1/dashboard/transport-health', {
    signal: opts?.signal,
  })
  return parseTransportHealthData(raw)
}
