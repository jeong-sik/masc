import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeLogsData,
  type LogCategory,
  type LogLevel,
  type LogsData,
  type LogsSchemaDriftError,
} from './schemas/logs'

export type { LogCategory, LogEntry, LogLevel, LogsData } from './schemas/logs'
export { decodeLogsData, LogsSchemaDriftError } from './schemas/logs'

export interface LogsRequest {
  readonly limit?: number
  readonly level?: LogLevel
  readonly module?: string
  readonly sinceSeq?: number
  readonly beforeSeq?: number
  readonly category?: LogCategory
  readonly excludeCategories?: readonly LogCategory[]
}

export type LogsError = DashboardTransportError | LogsSchemaDriftError

function logsPath(request: LogsRequest): string {
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
  if (request.category !== undefined) params.set('category', request.category)
  if (request.excludeCategories !== undefined && request.excludeCategories.length > 0) {
    params.set('exclude_category', request.excludeCategories.join(','))
  }
  const query = params.toString()
  return `/api/v1/dashboard/logs${query === '' ? '' : `?${query}`}`
}

export function fetchLogs(
  request: LogsRequest = {},
): Effect.Effect<LogsData, LogsError, DashboardHttp> {
  return Effect.gen(function*() {
    const http = yield* DashboardHttp
    const raw = yield* http.getUnknown(logsPath(request))
    return yield* decodeLogsData(raw)
  })
}
