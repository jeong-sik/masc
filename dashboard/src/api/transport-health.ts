import { get, type AbortableRequestOptions } from './core'
import {
  parseTransportHealthData,
  type HotSession,
  type TransportHealthData,
  type TransportHealthSnapshot,
} from './schemas/transport-health'

export type { HotSession, TransportHealthData, TransportHealthSnapshot }
export {
  isTransportHealthReady,
  parseTransportHealthData,
  TransportHealthSchemaDriftError,
} from './schemas/transport-health'

export async function fetchTransportHealth(
  opts?: AbortableRequestOptions,
): Promise<TransportHealthSnapshot> {
  const raw = await get<unknown>('/api/v1/dashboard/transport-health', {
    signal: opts?.signal,
    publicRead: true,
  })
  return parseTransportHealthData(raw)
}
