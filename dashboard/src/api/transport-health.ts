import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeTransportHealthData,
  type HotSession,
  type HttpListener,
  type HttpRateLimitResponse,
  type TransportHealthData,
  type TransportHealthSnapshot,
  type TransportHealthSchemaDriftError,
} from './schemas/transport-health'

export type {
  HotSession,
  HttpListener,
  HttpRateLimitResponse,
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

export function fetchTransportHealth(): Effect.Effect<
  TransportHealthSnapshot,
  TransportHealthError,
  DashboardHttp
> {
  return Effect.gen(function*() {
    const http = yield* DashboardHttp
    const raw = yield* http.getUnknown(TRANSPORT_HEALTH_PATH)
    return yield* decodeTransportHealthData(raw)
  })
}
