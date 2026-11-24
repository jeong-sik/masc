import {
  defaultDashboardHttp,
  type DashboardHttpService,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeDashboardConfig,
  type DashboardConfig,
  type DashboardConfigSchemaDriftError,
} from './schemas/dashboard-config'
import type { Result } from '../lib/result'

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

export async function fetchDashboardConfig(
  http: DashboardHttpService = defaultDashboardHttp,
  signal?: AbortSignal,
): Promise<Result<DashboardConfig, DashboardConfigError>> {
  const raw = await http.getUnknown(DASHBOARD_CONFIG_PATH, signal)
  if (!raw.ok) return raw
  return decodeDashboardConfig(raw.value)
}
