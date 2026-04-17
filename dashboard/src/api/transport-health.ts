import { get } from './core'
import {
  parseTransportHealthData,
  type HotSession,
  type TransportHealthData,
} from './schemas/transport-health'

export type { HotSession, TransportHealthData }
export { TransportHealthSchemaDriftError } from './schemas/transport-health'

type AbortableRequestOptions = {
  signal?: AbortSignal
}

// Thin null-returning wrapper preserving the pre-migration contract —
// `src/api/transport-health.test.ts` has many assertions on
// `decodeTransportHealthData(x) === null` for missing subsections.
// New call sites should use `parseTransportHealthData` directly for
// throw-on-drift semantics.
export function decodeTransportHealthData(raw: unknown): TransportHealthData | null {
  try {
    return parseTransportHealthData(raw)
  } catch {
    return null
  }
}

export async function fetchTransportHealth(
  opts?: AbortableRequestOptions,
): Promise<TransportHealthData> {
  const raw = await get<unknown>('/api/v1/dashboard/transport-health', {
    signal: opts?.signal,
  })
  return parseTransportHealthData(raw)
}
