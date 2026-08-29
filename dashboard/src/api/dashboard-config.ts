import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeDashboardConfig,
  type ConfigEntry,
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

function configEntry(
  data: DashboardConfig,
  env: string,
): ConfigEntry | undefined {
  return data.categories.dashboard?.find(entry => entry.env === env)
}

function threshold(
  data: DashboardConfig,
  env: string,
  fallback: number,
): number {
  const entry = configEntry(data, env)
  if (entry === undefined) return fallback
  const value = Number.parseFloat(entry.displayValue)
  return Number.isFinite(value) ? value : fallback
}

export function parseContextThresholds(
  data: DashboardConfig,
  defaults: { critical: number; warn: number; high: number },
): { critical: number; warn: number; high: number } {
  return {
    critical: threshold(
      data,
      'MASC_DASHBOARD_CTX_HANDOFF_IMMINENT',
      defaults.critical,
    ),
    warn: threshold(
      data,
      'MASC_DASHBOARD_CTX_PREPARING',
      defaults.warn,
    ),
    high: threshold(
      data,
      'MASC_DASHBOARD_CTX_HIGH',
      defaults.high,
    ),
  }
}
