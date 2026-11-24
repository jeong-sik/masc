import {
  defaultDashboardHttp,
  type DashboardHttpService,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeTransportHealthData,
  type HotSession,
  type HttpListener,
  type HttpRateLimitResponse,
  type HttpsListener,
  type TransportHealthData,
  type TransportHealthSnapshot,
  type TransportHealthSchemaDriftError,
} from './schemas/transport-health'
import type { Result } from '../lib/result'

export type {
  HotSession,
  HttpListener,
  HttpRateLimitResponse,
  HttpsListener,
  TransportHealthData,
  TransportHealthSnapshot,
}
export {
  decodeTransportHealthData,
  isTransportHealthReady,
  TransportHealthSchemaDriftError,
} from './schemas/transport-health'

export type TransportHealthError =
  | DashboardTransportError
  | TransportHealthSchemaDriftError

const TRANSPORT_HEALTH_PATH = '/api/v1/dashboard/transport-health'

export async function fetchTransportHealth(
  http: DashboardHttpService = defaultDashboardHttp,
  signal?: AbortSignal,
): Promise<Result<TransportHealthSnapshot, TransportHealthError>> {
  const raw = await http.getUnknown(TRANSPORT_HEALTH_PATH, signal)
  if (!raw.ok) return raw
  return decodeTransportHealthData(raw.value)
}
