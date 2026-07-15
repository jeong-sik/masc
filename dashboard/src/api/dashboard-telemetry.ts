// MASC Dashboard — Unified telemetry / dashboard cache stats fetchers.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { isRecord, asBoolean, asNumber, asRecordArray, asString } from '../components/common/normalize'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'

export type TelemetrySource =
  | 'keeper_metric'
  | 'agent_event'
  | 'tool_call_io'
  | 'trajectory_tool_call'
  | 'tool_usage'
  | 'oas_event'
  | 'execution_receipt'
  | 'tool_metric'

export type TelemetryEntry = Record<string, unknown> & {
  source: TelemetrySource
  ts?: number
  ts_unix?: number
  timestamp?: number
  ts_iso?: string
}

export type TelemetryResponse = {
  generated_at: string
  generated_at_iso?: string
  dashboard_surface?: string
  source?: string
  retention?: Record<string, unknown>
  query?: Record<string, unknown>
  count: number
  total_matching_entries?: number
  offset?: number
  has_more?: boolean
  truncated?: boolean
  entries: TelemetryEntry[]
}

export type DashboardCacheEntryDetail = {
  key: string
  kind: string
  ttl_remaining_ms?: number
  stale_remaining_ms?: number
  computing_for_ms?: number
  has_stale_fallback?: boolean
}

export type DashboardCacheStatsResponse = {
  entries: number
  fresh: number
  stale: number
  expired: number
  ready_fresh: number
  ready_stale: number
  computing: number
  max_entries: number
  hits_total: number
  misses_total: number
  hit_ratio: number
  timeout_circuit_open: number
  timeout_circuit_tracked: number
  entries_truncated_to: number
  entry_details: DashboardCacheEntryDetail[]
}

export type TelemetrySourceSummary = TelemetryFreshnessMetadata & {
  source: string
  path?: string
  entry_count: number
  keepers?: Array<{ name: string; path: string }>
  keeper_count?: number
}

export type TelemetrySummaryResponse = {
  generated_at: string
  sources: TelemetrySourceSummary[]
  total_entries: number
}

function decodeTelemetrySource(value: unknown): TelemetrySource | null {
  switch (value) {
    case 'keeper_metric':
    case 'agent_event':
    case 'tool_call_io':
    case 'trajectory_tool_call':
    case 'tool_usage':
    case 'oas_event':
    case 'execution_receipt':
    case 'tool_metric':
      return value
    default:
      return null
  }
}

function decodeTelemetryEntry(raw: unknown): TelemetryEntry | null {
  if (!isRecord(raw)) return null
  const source = decodeTelemetrySource(raw.source)
  if (!source) return null
  return {
    ...raw,
    source,
    ts: asNumber(raw.ts),
    ts_unix: asNumber(raw.ts_unix),
    timestamp: asNumber(raw.timestamp),
    ts_iso: asString(raw.ts_iso),
  }
}

function decodeTelemetryResponse(raw: unknown): TelemetryResponse | null {
  if (!isRecord(raw)) return null
  const generatedAt = asString(raw.generated_at)
  if (!generatedAt) return null
  return {
    generated_at: generatedAt,
    generated_at_iso: asString(raw.generated_at_iso),
    dashboard_surface: asString(raw.dashboard_surface),
    source: asString(raw.source),
    retention: isRecord(raw.retention) ? raw.retention : undefined,
    query: isRecord(raw.query) ? raw.query : undefined,
    count: asNumber(raw.count, 0),
    total_matching_entries: asNumber(raw.total_matching_entries, asNumber(raw.count, 0)),
    offset: asNumber(raw.offset, 0),
    has_more: asBoolean(raw.has_more, false),
    truncated: asBoolean(raw.truncated, false),
    entries: asRecordArray(raw.entries)
      .map(decodeTelemetryEntry)
      .filter((entry): entry is TelemetryEntry => entry !== null),
  }
}

function decodeDashboardCacheEntryDetail(raw: unknown): DashboardCacheEntryDetail | null {
  if (!isRecord(raw)) return null
  const key = asString(raw.key)
  const kind = asString(raw.kind)
  if (!key || !kind) return null
  return {
    key,
    kind,
    ttl_remaining_ms: asNumber(raw.ttl_remaining_ms),
    stale_remaining_ms: asNumber(raw.stale_remaining_ms),
    computing_for_ms: asNumber(raw.computing_for_ms),
    has_stale_fallback: asBoolean(raw.has_stale_fallback),
  }
}

function decodeDashboardCacheStatsResponse(raw: unknown): DashboardCacheStatsResponse | null {
  if (!isRecord(raw)) return null
  return {
    entries: asNumber(raw.entries, 0),
    fresh: asNumber(raw.fresh, 0),
    stale: asNumber(raw.stale, 0),
    expired: asNumber(raw.expired, 0),
    ready_fresh: asNumber(raw.ready_fresh, 0),
    ready_stale: asNumber(raw.ready_stale, 0),
    computing: asNumber(raw.computing, 0),
    max_entries: asNumber(raw.max_entries, 0),
    hits_total: asNumber(raw.hits_total, 0),
    misses_total: asNumber(raw.misses_total, 0),
    hit_ratio: asNumber(raw.hit_ratio, 0),
    timeout_circuit_open: asNumber(raw.timeout_circuit_open, 0),
    timeout_circuit_tracked: asNumber(raw.timeout_circuit_tracked, 0),
    entries_truncated_to: asNumber(raw.entries_truncated_to, 0),
    entry_details: asRecordArray(raw.entry_details)
      .map(decodeDashboardCacheEntryDetail)
      .filter((entry): entry is DashboardCacheEntryDetail => entry !== null),
  }
}

function decodeTelemetrySourceSummary(raw: unknown): TelemetrySourceSummary | null {
  if (!isRecord(raw)) return null
  const source = asString(raw.source)
  if (!source) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    source,
    path: asString(raw.path),
    exists: asBoolean(raw.exists),
    entry_count: asNumber(raw.entry_count, 0),
    keepers: asRecordArray(raw.keepers)
      .map((keeper) => {
        const name = asString(keeper.name)
        const path = asString(keeper.path)
        return name && path ? { name, path } : null
      })
      .filter((keeper): keeper is { name: string; path: string } => keeper !== null),
    keeper_count: asNumber(raw.keeper_count),
  }
}

function decodeTelemetrySummaryResponse(raw: unknown): TelemetrySummaryResponse | null {
  if (!isRecord(raw)) return null
  const generatedAt = asString(raw.generated_at)
  if (!generatedAt) return null
  return {
    generated_at: generatedAt,
    sources: asRecordArray(raw.sources)
      .map(decodeTelemetrySourceSummary)
      .filter((summary): summary is TelemetrySourceSummary => summary !== null),
    total_entries: asNumber(raw.total_entries, 0),
  }
}

export function fetchTelemetry(opts?: {
  source?: TelemetrySource
  keeper?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
  since_ms?: number
  until_ms?: number
  n?: number
  offset?: number
  signal?: AbortSignal
}): Promise<TelemetryResponse> {
  const params = new URLSearchParams()
  if (opts?.source) params.set('source', opts.source)
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.session_id) params.set('session_id', opts.session_id)
  if (opts?.operation_id) params.set('operation_id', opts.operation_id)
  if (opts?.worker_run_id) params.set('worker_run_id', opts.worker_run_id)
  if (typeof opts?.since_ms === 'number') params.set('since_ms', String(opts.since_ms))
  if (typeof opts?.until_ms === 'number') params.set('until_ms', String(opts.until_ms))
  if (typeof opts?.n === 'number') params.set('n', String(opts.n))
  if (typeof opts?.offset === 'number') params.set('offset', String(opts.offset))
  const qs = params.toString()
  return get<Record<string, unknown>>(`/api/v1/dashboard/telemetry${qs ? '?' + qs : ''}`, { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeTelemetryResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 telemetry payload')
      return decoded
    })
}

export function fetchTelemetrySummary(opts?: AbortableRequestOptions): Promise<TelemetrySummaryResponse> {
  return get<Record<string, unknown>>('/api/v1/dashboard/telemetry/summary', { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeTelemetrySummaryResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 telemetry summary payload')
      return decoded
    })
}

export function fetchDashboardCacheStats(opts?: AbortableRequestOptions): Promise<DashboardCacheStatsResponse> {
  return get<Record<string, unknown>>('/api/v1/dashboard/cache-stats', { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeDashboardCacheStatsResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 dashboard cache stats payload')
      return decoded
    })
}
