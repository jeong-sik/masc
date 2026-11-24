import {
  defaultDashboardHttp,
  type DashboardHttpService,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeLogsData,
  type LogCategory,
  type LogCategorySelector,
  type LogLevel,
  type LogsData,
  type LogsSchemaDriftError,
} from './schemas/logs'
import type { Result } from '../lib/result'

export type { LogCategory, LogEntry, LogLevel, LogsData } from './schemas/logs'
export { decodeLogsData, LogsSchemaDriftError } from './schemas/logs'

export interface LogsRequest {
  readonly limit?: number
  readonly level?: LogLevel
  readonly module?: string
  readonly sinceSeq?: number
  readonly beforeSeq?: number
  readonly categories?: readonly LogCategorySelector[]
  readonly excludeCategories?: readonly LogCategory[]
}

export type LogsError = DashboardTransportError | LogsSchemaDriftError

export function logsPath(request: LogsRequest, stream = false): string {
  const params = new URLSearchParams()
  if (request.limit !== undefined) params.set('limit', String(request.limit))
  if (request.level !== undefined) params.set('level', request.level)
  if (request.module !== undefined && request.module !== '') {
    params.set('module', request.module)
  }
  if (request.sinceSeq !== undefined && request.sinceSeq >= 0) {
    params.set('since_seq', String(request.sinceSeq))
  }
  if (request.beforeSeq !== undefined && request.beforeSeq >= 0) {
    params.set('before_seq', String(request.beforeSeq))
  }
  if (request.categories !== undefined && request.categories.length > 0) {
    params.set('category', request.categories.join(','))
  }
  if (request.excludeCategories !== undefined && request.excludeCategories.length > 0) {
    params.set('exclude_category', request.excludeCategories.join(','))
  }
  const query = params.toString()
  return `/api/v1/dashboard/logs${stream ? '/stream' : ''}${query === '' ? '' : `?${query}`}`
}

export async function fetchLogs(
  request: LogsRequest = {},
  http: DashboardHttpService = defaultDashboardHttp,
  signal?: AbortSignal,
): Promise<Result<LogsData, LogsError>> {
  const raw = await http.getUnknown(logsPath(request), signal)
  if (!raw.ok) return raw
  return decodeLogsData(raw.value)
}
