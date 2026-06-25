// MASC Dashboard — keeper tool stats (server-side aggregation).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { isRecord, asNumber, asRecordArray, asString } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'

export type ToolStat = {
  name: string
  call_count: number
  success_count: number
  failure_count: number
  avg_duration_ms: number
  p95_duration_ms: number
  max_duration_ms: number
  total_cost_usd: number
  last_used_at: string
}

export type HourlyBucket = {
  hour: string
  call_count: number
  error_count: number
}

export type ToolStatsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  window_hours: number
  total_entries: number
  tools: ToolStat[]
  timeline: HourlyBucket[]
}

function decodeToolStat(raw: unknown): ToolStat | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    call_count: asNumber(raw.call_count, 0),
    success_count: asNumber(raw.success_count, 0),
    failure_count: asNumber(raw.failure_count, 0),
    avg_duration_ms: asNumber(raw.avg_duration_ms, 0),
    p95_duration_ms: asNumber(raw.p95_duration_ms, 0),
    max_duration_ms: asNumber(raw.max_duration_ms, 0),
    total_cost_usd: asNumber(raw.total_cost_usd, 0),
    last_used_at: asString(raw.last_used_at, ''),
  }
}

function decodeHourlyBucket(raw: unknown): HourlyBucket | null {
  if (!isRecord(raw)) return null
  const hour = asString(raw.hour)
  if (!hour) return null
  return {
    hour,
    call_count: asNumber(raw.call_count, 0),
    error_count: asNumber(raw.error_count, 0),
  }
}

function decodeToolStatsResponse(raw: unknown): ToolStatsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    window_hours: asNumber(raw.window_hours, 24),
    total_entries: asNumber(raw.total_entries, 0),
    tools: asRecordArray(raw.tools)
      .map(decodeToolStat)
      .filter((tool): tool is ToolStat => tool !== null),
    timeline: asRecordArray(raw.timeline)
      .map(decodeHourlyBucket)
      .filter((bucket): bucket is HourlyBucket => bucket !== null),
  }
}

export function fetchKeeperToolStats(
  name: string,
  windowHours?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolStatsResponse> {
  const params = windowHours != null ? `?window_hours=${windowHours}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-stats${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolStatsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool stats payload')
    return decoded
  })
}
