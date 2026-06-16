// SourceHealth — pure helper for telemetry/tool source health tone mapping.
//
// Consolidated from 4 duplicated inline definitions:
//   keeper-tool-call-inspector, tools/tools-main, keeper-tool-telemetry,
//   tool-quality-panel.
//
// The mapping is stable across the dashboard: ok → success tone,
// stale/coverage_gap/empty → warning tone, missing → bad tone,
// everything else → disabled neutral tone.

import { formatElapsedCompact } from '../../lib/format-time'
import type { TelemetryCoverageGap, TelemetryFreshnessMetadata } from '../../api/dashboard'

/** Map a source health string to a Tailwind text color class. */
export function sourceHealthClass(health?: string | null): string {
  switch ((health ?? '').toLowerCase()) {
    case 'ok':
      return 'text-[var(--color-status-ok)]'
    case 'stale':
    case 'coverage_gap':
    case 'empty':
      return 'text-[var(--color-status-warn)]'
    case 'missing':
      return 'text-[var(--bad-light)]'
    default:
      return 'text-[var(--color-fg-disabled)]'
  }
}

/** Format telemetry freshness metadata into a human-readable label. */
export function freshnessText(d: TelemetryFreshnessMetadata): string {
  if (d.stale_reason) return humanizeCoverageReason(d.stale_reason)
  if (typeof d.latest_age_s !== 'number' || !Number.isFinite(d.latest_age_s)) {
    return 'latest n/a'
  }
  return `latest ${formatElapsedCompact(d.latest_age_s)}`
}

function nonEmpty(value?: string | null): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

// Backends emit `coverage_gaps` in oldest→newest order (see
// `lib/dashboard/dashboard_http_keeper.ml`, `lib/dashboard_tool_source_freshness.ml`,
// `lib/server/server_dashboard_http_keeper_api.ml` — each derives "latest" via
// `List.rev coverage_gaps |> List.find_opt`). Pick the tail so the UI surfaces
// provenance for the *current* incident, not a stale one.
function latestCoverageGap(d: TelemetryFreshnessMetadata): TelemetryCoverageGap | null {
  const gaps = d.coverage_gaps
  if (!gaps || gaps.length === 0) return null
  return gaps[gaps.length - 1] ?? null
}

export type CoverageGapDisplay = {
  count: number
  summary: string
  details: string[]
  // Structured split of `details` so panels can keep the operator-facing
  // diagnosis separate from raw provenance. `details` remains the flat SSOT
  // for compact callers that just want strings.
  structured: {
    reason: string
    title: string
    stateLabel: string
    latest: string | null
    impact: string
    producer: string | null
    store: string | null
    surface: string | null
    trace: string | null
    error: string | null
    // RFC-0154 PR-3: backend-classified short tag. Absent on v1 wire rows
    // (pre-RFC-0154 PR-2 deployment); present on v2 rows. Consumers should
    // prefer this typed lookup over substring matching on `error`.
    errorClass: string | null
  }
}

const ACTIVE_GAP_AGE_S = 15 * 60
const RECENT_GAP_AGE_S = 24 * 60 * 60

export function humanizeCoverageReason(reason: string): string {
  switch (reason) {
    case 'tool_call_io_append_failed':
      return 'tool-call log write failed'
    case 'tool_call_io_store_unavailable':
      return 'tool-call log unavailable'
    case 'tool_call_io_init_failed':
      return 'tool-call log init failed'
    case 'trajectory_append_failed':
      return 'tool trajectory write failed'
    case 'execution_receipt_append_failed':
      return 'execution receipt write failed'
    case 'freshness_slo_exceeded':
      return 'freshness SLO exceeded'
    case 'store_missing':
      return 'store missing'
    case 'no_entries':
      return 'no entries'
    default:
      return reason.replace(/_/g, ' ')
  }
}

function titleForCoverageGap(source: string | null, reason: string): string {
  switch (reason) {
    case 'tool_call_io_append_failed':
      return 'Tool-call log write failed'
    case 'tool_call_io_store_unavailable':
      return 'Tool-call log unavailable'
    case 'tool_call_io_init_failed':
      return 'Tool-call log init failed'
    case 'trajectory_append_failed':
      return 'Tool trajectory write failed'
    case 'execution_receipt_append_failed':
      return 'Execution receipt write failed'
    default:
      if (reason.endsWith('_append_failed')) return 'Telemetry write failed'
      if (source === 'tool_call_io') return 'Tool-call telemetry coverage issue'
      return 'Telemetry coverage issue'
  }
}

function impactForCoverageGap(source: string | null, reason: string, surface: string | null): string {
  if (reason === 'tool_call_io_append_failed' || source === 'tool_call_io') {
    return 'Tool Monitor may undercount keeper tool I/O around this trace.'
  }
  if (reason === 'trajectory_append_failed' || source === 'trajectory_tool_call') {
    return 'Keeper tool stats or trajectory drilldowns may miss events around this trace.'
  }
  if (reason === 'execution_receipt_append_failed' || source === 'execution_receipt') {
    return 'Execution-trust views may miss receipt evidence around this trace.'
  }
  if (surface) return 'This dashboard surface may be missing telemetry rows.'
  return 'One telemetry lane may be missing rows.'
}

function gapUnixSeconds(gap: TelemetryCoverageGap | null): number | null {
  if (!gap) return null
  if (typeof gap.ts === 'number' && Number.isFinite(gap.ts) && gap.ts > 0) return gap.ts
  const parsed = gap.ts_iso ? Date.parse(gap.ts_iso) : Number.NaN
  if (!Number.isFinite(parsed)) return null
  return parsed / 1000
}

function latestGapText(gap: TelemetryCoverageGap | null): string | null {
  const ts = gapUnixSeconds(gap)
  if (ts != null) {
    const age = Math.max(0, Date.now() / 1000 - ts)
    return `latest gap ${formatElapsedCompact(age)} ago`
  }
  return nonEmpty(gap?.ts_iso) ? `latest gap ${gap?.ts_iso}` : null
}

function stateLabelForGap(gap: TelemetryCoverageGap | null): string {
  const ts = gapUnixSeconds(gap)
  if (ts == null) return 'recorded'
  const age = Math.max(0, Date.now() / 1000 - ts)
  if (age <= ACTIVE_GAP_AGE_S) return 'active'
  if (age <= RECENT_GAP_AGE_S) return 'recent'
  return 'historical'
}

function recordedGapCount(count: number): string {
  return count === 1 ? '1 recorded gap' : `${count} recorded gaps`
}

/** Build compact operator-visible coverage-gap details for freshness lines. */
export function coverageGapDisplay(d: TelemetryFreshnessMetadata): CoverageGapDisplay | null {
  const count = d.coverage_gap_count ?? d.coverage_gaps?.length ?? 0
  if (count <= 0) return null

  const gap = latestCoverageGap(d)
  const reason = nonEmpty(gap?.stale_reason) ?? nonEmpty(d.stale_reason) ?? 'coverage_gap'
  const source = nonEmpty(gap?.source) ?? nonEmpty(d.source)
  const producer = nonEmpty(gap?.producer) ?? nonEmpty(d.producer)
  const store = nonEmpty(gap?.durable_store) ?? nonEmpty(d.durable_store)
  const surface = nonEmpty(gap?.dashboard_surface) ?? nonEmpty(d.dashboard_surface)
  const trace = nonEmpty(gap?.trace_id)
  const errorValue = nonEmpty(gap?.error)
  const errorClass = nonEmpty(gap?.error_class)
  const title = titleForCoverageGap(source, reason)
  const latest = latestGapText(gap)
  const stateLabel = stateLabelForGap(gap)
  const impact = impactForCoverageGap(source, reason, surface)
  const detailRows: Array<[string, string | null]> = [
    ['status', latest ? `${stateLabel} · ${latest}` : stateLabel],
    ['impact', impact],
    ['reason', reason],
    ['producer', producer],
    ['store', store],
    ['surface', surface],
    ['trace', trace],
    ['error', errorValue],
  ]
  const details = detailRows
    .filter((entry): entry is [string, string] => entry[1] != null)
    .map(([label, value]) => `${label} ${value}`)

  // Surface the still-unrecovered count when it is a strict subset of the
  // total (source latest_ts has caught up on the rest); skip when all gaps are
  // active or none are, to avoid a redundant "N active" on the total.
  const active = d.active_coverage_gap_count
  const activeSuffix =
    typeof active === 'number' && active > 0 && active < count ? ` · ${active} active` : ''

  return {
    count,
    summary: `${title} · ${recordedGapCount(count)}${activeSuffix}`,
    details,
    structured: {
      reason,
      title,
      stateLabel,
      latest,
      impact,
      producer,
      store,
      surface,
      trace,
      error: errorValue,
      errorClass,
    },
  }
}
