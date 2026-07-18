// MASC Dashboard — keeper tool stats (server-side aggregation).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'
import {
  decodeTrajectoryCount,
  decodeTrajectoryNonBlankString,
  decodeTrajectoryInvalidReasons,
  decodeTrajectoryReadErrors,
  trajectoryInvalidReasonCount,
  type TrajectoryInvalidReasons,
  type TrajectoryReadError,
} from './dashboard-keeper-trajectory'

export type ToolStat = {
  name: string
  call_count: number
  success_count: number
  failure_count: number
  avg_duration_ms: number
  p95_duration_ms: number
  max_duration_ms: number
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
  decode: {
    invalid_entry_count: number
    invalid_reasons: TrajectoryInvalidReasons
  }
  io_errors: TrajectoryReadError[]
  tools: ToolStat[]
  timeline: HourlyBucket[]
}

function decodeToolStat(raw: unknown): ToolStat | null {
  if (!isRecord(raw) || !hasOnlyKeys(raw, TOOL_STAT_KEYS)) return null
  const name = decodeTrajectoryNonBlankString(raw.name)
  const callCount = decodeTrajectoryCount(raw.call_count)
  const successCount = decodeTrajectoryCount(raw.success_count)
  const failureCount = decodeTrajectoryCount(raw.failure_count)
  const avgDurationMs = decodeTrajectoryCount(raw.avg_duration_ms)
  const p95DurationMs = decodeTrajectoryCount(raw.p95_duration_ms)
  const maxDurationMs = decodeTrajectoryCount(raw.max_duration_ms)
  const lastUsedAt = decodeTrajectoryNonBlankString(raw.last_used_at)
  if (
    name === null
    || callCount === null
    || successCount === null
    || failureCount === null
    || avgDurationMs === null
    || p95DurationMs === null
    || maxDurationMs === null
    || lastUsedAt === null
    || successCount + failureCount !== callCount
  ) return null
  return {
    name,
    call_count: callCount,
    success_count: successCount,
    failure_count: failureCount,
    avg_duration_ms: avgDurationMs,
    p95_duration_ms: p95DurationMs,
    max_duration_ms: maxDurationMs,
    last_used_at: lastUsedAt,
  }
}

function decodeHourlyBucket(raw: unknown): HourlyBucket | null {
  if (!isRecord(raw) || !hasOnlyKeys(raw, HOURLY_BUCKET_KEYS)) return null
  const hour = decodeTrajectoryNonBlankString(raw.hour)
  const callCount = decodeTrajectoryCount(raw.call_count)
  const errorCount = decodeTrajectoryCount(raw.error_count)
  if (hour === null || callCount === null || errorCount === null || errorCount > callCount) return null
  return {
    hour,
    call_count: callCount,
    error_count: errorCount,
  }
}

function decodeToolStatsResponse(raw: unknown): ToolStatsResponse | null {
  if (
    !isRecord(raw)
    || !hasOnlyKeys(raw, TOOL_STATS_RESPONSE_KEYS)
    || !hasClosedTelemetryMetadata(raw)
  ) return null
  const keeper = decodeTrajectoryNonBlankString(raw.keeper)
  const windowHours = decodeTrajectoryCount(raw.window_hours)
  const totalEntries = decodeTrajectoryCount(raw.total_entries)
  const decode = raw.decode
  if (
    keeper === null
    || windowHours === null
    || windowHours === 0
    || totalEntries === null
    || !isRecord(decode)
    || !hasOnlyKeys(decode, TOOL_STATS_DECODE_KEYS)
  ) return null
  const invalidEntryCount = decodeTrajectoryCount(decode.invalid_entry_count)
  const invalidReasons = decodeTrajectoryInvalidReasons(decode.invalid_reasons)
  if (
    invalidEntryCount === null
    || invalidReasons === null
  ) return null
  if (
    trajectoryInvalidReasonCount(invalidReasons) !== invalidEntryCount
  ) return null
  const ioErrors = decodeTrajectoryReadErrors(raw.io_errors)
  if (ioErrors === null) return null
  if (!Array.isArray(raw.tools) || !Array.isArray(raw.timeline)) return null
  const tools: ToolStat[] = []
  for (const item of raw.tools) {
    const decoded = decodeToolStat(item)
    if (decoded === null) return null
    tools.push(decoded)
  }
  const timeline: HourlyBucket[] = []
  for (const item of raw.timeline) {
    const decoded = decodeHourlyBucket(item)
    if (decoded === null) return null
    timeline.push(decoded)
  }
  if (
    tools.reduce((sum, tool) => sum + tool.call_count, 0) !== totalEntries
    || timeline.reduce((sum, bucket) => sum + bucket.call_count, 0) !== totalEntries
  ) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    window_hours: windowHours,
    total_entries: totalEntries,
    decode: {
      invalid_entry_count: invalidEntryCount,
      invalid_reasons: invalidReasons,
    },
    io_errors: ioErrors,
    tools,
    timeline,
  }
}

const TOOL_STAT_KEYS = new Set([
  'name', 'call_count', 'success_count', 'failure_count', 'avg_duration_ms',
  'p95_duration_ms', 'max_duration_ms', 'last_used_at',
])
const HOURLY_BUCKET_KEYS = new Set(['hour', 'call_count', 'error_count'])
const TOOL_STATS_DECODE_KEYS = new Set(['invalid_entry_count', 'invalid_reasons'])
const TOOL_STATS_RESPONSE_KEYS = new Set([
  'keeper', 'window_hours', 'total_entries', 'decode', 'io_errors', 'tools',
  'timeline', 'source', 'producer', 'durable_store', 'dashboard_surface',
  'dashboard_surface_envelope', 'freshness_slo_s', 'latest_ts_unix',
  'latest_ts_iso', 'latest_age_s', 'health', 'stale_reason', 'entry_count',
  'exists', 'coverage_gaps', 'coverage_gap_count', 'active_coverage_gap_count',
])
const SURFACE_ENVELOPE_KEYS = new Set([
  'schema', 'schema_version', 'surface', 'source', 'generated_at_iso', 'cache',
  'migration',
])
const SURFACE_CACHE_KEYS = new Set([
  'state', 'key', 'ttl_s', 'stale', 'stale_reason', 'latest_age_s', 'health',
])
const SURFACE_MIGRATION_KEYS = new Set(['body_shape', 'rule'])
const COVERAGE_GAP_KEYS = new Set([
  'schema', 'ts', 'ts_iso', 'source', 'producer', 'durable_store',
  'dashboard_surface', 'stale_reason', 'keeper_name', 'trace_id', 'error',
  'error_class',
])

function hasOnlyKeys(raw: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(raw).every(key => allowed.has(key))
}

function hasExactKeys(raw: Record<string, unknown>, expected: ReadonlySet<string>): boolean {
  return Object.keys(raw).length === expected.size && hasOnlyKeys(raw, expected)
}

function validOptionalString(raw: Record<string, unknown>, key: string): boolean {
  return raw[key] === undefined || typeof raw[key] === 'string'
}

function validOptionalNullableString(raw: Record<string, unknown>, key: string): boolean {
  return raw[key] === undefined || raw[key] === null || typeof raw[key] === 'string'
}

function validOptionalFiniteNumber(raw: Record<string, unknown>, key: string): boolean {
  return raw[key] === undefined
    || (typeof raw[key] === 'number' && Number.isFinite(raw[key]))
}

function validOptionalNullableFiniteNumber(raw: Record<string, unknown>, key: string): boolean {
  return raw[key] === null || validOptionalFiniteNumber(raw, key)
}

function validOptionalCount(raw: Record<string, unknown>, key: string): boolean {
  return raw[key] === undefined || decodeTrajectoryCount(raw[key]) !== null
}

function hasClosedSurfaceEnvelope(raw: unknown): boolean {
  if (!isRecord(raw) || !hasExactKeys(raw, SURFACE_ENVELOPE_KEYS)) return false
  if (
    !validOptionalString(raw, 'schema')
    || !validOptionalFiniteNumber(raw, 'schema_version')
    || !validOptionalString(raw, 'surface')
    || !validOptionalString(raw, 'source')
    || !validOptionalString(raw, 'generated_at_iso')
  ) return false
  if (raw.cache !== undefined) {
    if (!isRecord(raw.cache) || !hasExactKeys(raw.cache, SURFACE_CACHE_KEYS)) return false
    if (
      !validOptionalString(raw.cache, 'state')
      || !validOptionalNullableString(raw.cache, 'key')
      || !validOptionalNullableFiniteNumber(raw.cache, 'ttl_s')
      || (raw.cache.stale !== undefined && typeof raw.cache.stale !== 'boolean')
      || !validOptionalNullableString(raw.cache, 'stale_reason')
      || !validOptionalNullableFiniteNumber(raw.cache, 'latest_age_s')
      || !validOptionalNullableString(raw.cache, 'health')
    ) return false
  }
  if (raw.migration !== undefined) {
    if (!isRecord(raw.migration) || !hasExactKeys(raw.migration, SURFACE_MIGRATION_KEYS)) return false
    if (
      !validOptionalString(raw.migration, 'body_shape')
      || !validOptionalString(raw.migration, 'rule')
    ) return false
  }
  return true
}

function hasClosedCoverageGaps(raw: unknown): boolean {
  if (raw === undefined) return true
  if (!Array.isArray(raw)) return false
  return raw.every((gap) => {
    if (!isRecord(gap) || !hasExactKeys(gap, COVERAGE_GAP_KEYS)) return false
    return validOptionalString(gap, 'schema')
      && validOptionalFiniteNumber(gap, 'ts')
      && validOptionalNullableString(gap, 'ts_iso')
      && validOptionalString(gap, 'source')
      && validOptionalString(gap, 'producer')
      && validOptionalString(gap, 'durable_store')
      && validOptionalString(gap, 'dashboard_surface')
      && validOptionalString(gap, 'stale_reason')
      && validOptionalNullableString(gap, 'keeper_name')
      && validOptionalNullableString(gap, 'trace_id')
      && validOptionalNullableString(gap, 'error')
      && validOptionalNullableString(gap, 'error_class')
  })
}

function hasClosedTelemetryMetadata(raw: Record<string, unknown>): boolean {
  if (
    !validOptionalString(raw, 'source')
    || !validOptionalString(raw, 'producer')
    || !validOptionalString(raw, 'durable_store')
    || !validOptionalString(raw, 'dashboard_surface')
    || !validOptionalFiniteNumber(raw, 'freshness_slo_s')
    || !validOptionalNullableFiniteNumber(raw, 'latest_ts_unix')
    || !validOptionalNullableString(raw, 'latest_ts_iso')
    || !validOptionalNullableFiniteNumber(raw, 'latest_age_s')
    || !validOptionalString(raw, 'health')
    || !validOptionalNullableString(raw, 'stale_reason')
    || !validOptionalCount(raw, 'entry_count')
    || (raw.exists !== undefined && typeof raw.exists !== 'boolean')
    || !validOptionalCount(raw, 'coverage_gap_count')
    || !validOptionalCount(raw, 'active_coverage_gap_count')
    || !hasClosedCoverageGaps(raw.coverage_gaps)
  ) return false
  return raw.dashboard_surface_envelope === undefined
    || hasClosedSurfaceEnvelope(raw.dashboard_surface_envelope)
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
