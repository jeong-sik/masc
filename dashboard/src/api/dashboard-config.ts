import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeDashboardConfig,
  type DashboardConfig,
  type DashboardConfigSchemaDriftError,
} from './schemas/dashboard-config'

export type {
  ConfigEntry,
  ConfigEntrySource,
  DashboardConfig,
} from './schemas/dashboard-config'
export {
  decodeDashboardConfig,
  DashboardConfigSchemaDriftError,
} from './schemas/dashboard-config'

export type DashboardConfigError =
  | DashboardTransportError
  | DashboardConfigSchemaDriftError

const DASHBOARD_CONFIG_PATH = '/api/v1/dashboard/config'

export function fetchDashboardConfig(): Effect.Effect<
  DashboardConfig,
  DashboardConfigError,
  DashboardHttp
> {
  return Effect.gen(function*() {
    const http = yield* DashboardHttp
    const raw = yield* http.getUnknown(DASHBOARD_CONFIG_PATH)
    return yield* decodeDashboardConfig(raw)
  })
}
