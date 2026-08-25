import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeFeatureHealthData,
  type FeatureHealthCategory,
  type FeatureHealthData,
  type FeatureHealthItem,
  type FeatureHealthSchemaDriftError,
  type FeatureStatus,
} from './schemas/feature-health'

export type {
  FeatureHealthCategory,
  FeatureHealthData,
  FeatureHealthItem,
  FeatureStatus,
}
export {
  decodeFeatureHealthData,
  FeatureHealthSchemaDriftError,
} from './schemas/feature-health'

export type FeatureHealthError =
  | DashboardTransportError
  | FeatureHealthSchemaDriftError

const FEATURE_HEALTH_PATH = '/api/v1/dashboard/feature-health'

export function fetchFeatureHealth(): Effect.Effect<
  FeatureHealthData,
  FeatureHealthError,
  DashboardHttp
> {
  return Effect.gen(function*() {
    const http = yield* DashboardHttp
    const raw = yield* http.getUnknown(FEATURE_HEALTH_PATH)
    return yield* decodeFeatureHealthData(raw)
  })
}
