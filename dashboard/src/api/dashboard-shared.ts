// MASC Dashboard — shared feed/telemetry types + decoders.
// Extracted from dashboard.ts. Consumed across logs/cost/execution/tool-stats/telemetry
// domains. Public symbols are re-exported from dashboard.ts so consumers are unchanged.

import { isRecord, asBoolean, asNumber, asNullableString, asRecordArray, asString } from '../components/common/normalize'

export type DashboardFeedRetention = Record<string, unknown> & {
  scope?: string
  durable_store?: string
  durable_replay_surface?: string
}

export type DashboardFeedMetadata = {
  generated_at_iso?: string
  dashboard_surface?: string
  source?: string
  retention?: DashboardFeedRetention
}

export function decodeDashboardFeedMetadata(raw: Record<string, unknown>): DashboardFeedMetadata {
  return {
    generated_at_iso: asString(raw.generated_at_iso),
    dashboard_surface: asString(raw.dashboard_surface),
    source: asString(raw.source),
    retention: isRecord(raw.retention) ? raw.retention : undefined,
  }
}

export type TelemetryFreshnessMetadata = {
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  dashboard_surface_envelope?: DashboardSurfaceEnvelope | null
  freshness_slo_s?: number | null
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
  entry_count?: number
  exists?: boolean
  coverage_gaps?: TelemetryCoverageGap[]
  coverage_gap_count?: number
  // Count of gaps not yet recovered (source latest_ts < gap ts), distinct from
  // the total coverage_gap_count — the actionable "still failing" number.
  active_coverage_gap_count?: number
}

export type DashboardSurfaceEnvelope = {
  schema?: string
  schema_version?: number
  surface?: string
  source?: string
  generated_at_iso?: string
  cache?: {
    state?: string
    key?: string | null
    ttl_s?: number | null
    stale?: boolean
    stale_reason?: string | null
    latest_age_s?: number | null
    health?: string | null
  }
  migration?: {
    body_shape?: string
    rule?: string
  }
}

export type TelemetryCoverageGap = {
  schema?: string
  ts?: number
  ts_iso?: string | null
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  stale_reason?: string
  keeper_name?: string | null
  trace_id?: string | null
  error?: string | null
  // RFC-0154 PR-2: backend-classified typed tag. Absent on v1 rows; present
  // on v2 rows. Values are the short tags from `System_error_class.to_short_tag`
  // ("fd_exhaustion" / "disk_exhaustion" / "permission_denied" /
  // "connection_refused" / "timeout" / "other"). Consumers should fall back to
  // substring matching on `error` when this field is null (legacy / pre-PR-2).
  error_class?: string | null
}

function decodeDashboardSurfaceEnvelope(raw: unknown): DashboardSurfaceEnvelope | null {
  if (!isRecord(raw)) return null
  const cache = isRecord(raw.cache)
    ? {
        state: asString(raw.cache.state),
        key: asNullableString(raw.cache.key),
        ttl_s: asNumber(raw.cache.ttl_s),
        stale: asBoolean(raw.cache.stale),
        stale_reason: asNullableString(raw.cache.stale_reason),
        latest_age_s: asNumber(raw.cache.latest_age_s),
        health: asNullableString(raw.cache.health),
      }
    : undefined
  const migration = isRecord(raw.migration)
    ? {
        body_shape: asString(raw.migration.body_shape),
        rule: asString(raw.migration.rule),
      }
    : undefined
  return {
    schema: asString(raw.schema),
    schema_version: asNumber(raw.schema_version),
    surface: asString(raw.surface),
    source: asString(raw.source),
    generated_at_iso: asString(raw.generated_at_iso),
    cache,
    migration,
  }
}

function decodeTelemetryCoverageGap(raw: unknown): TelemetryCoverageGap | null {
  if (!isRecord(raw)) return null
  return {
    schema: asString(raw.schema),
    ts: asNumber(raw.ts),
    ts_iso: asNullableString(raw.ts_iso),
    source: asString(raw.source),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    stale_reason: asString(raw.stale_reason),
    keeper_name: asNullableString(raw.keeper_name),
    trace_id: asNullableString(raw.trace_id),
    error: asNullableString(raw.error),
    error_class: asNullableString(raw.error_class),
  }
}

export function decodeTelemetryFreshnessMetadata(raw: Record<string, unknown>): TelemetryFreshnessMetadata {
  const coverageGaps = asRecordArray(raw.coverage_gaps)
    .map(decodeTelemetryCoverageGap)
    .filter((gap): gap is TelemetryCoverageGap => gap !== null)
  return {
    source: asString(raw.source),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    dashboard_surface_envelope: decodeDashboardSurfaceEnvelope(raw.dashboard_surface_envelope),
    freshness_slo_s: asNumber(raw.freshness_slo_s),
    latest_ts_unix: asNumber(raw.latest_ts_unix),
    latest_ts_iso: asNullableString(raw.latest_ts_iso),
    latest_age_s: asNumber(raw.latest_age_s),
    health: asString(raw.health),
    stale_reason: asNullableString(raw.stale_reason),
    entry_count: asNumber(raw.entry_count),
    exists: asBoolean(raw.exists),
    coverage_gaps: coverageGaps,
    coverage_gap_count: asNumber(raw.coverage_gap_count, coverageGaps.length),
    active_coverage_gap_count: asNumber(raw.active_coverage_gap_count),
  }
}
