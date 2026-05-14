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
  if (d.stale_reason) return d.stale_reason
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
}

/** Build compact operator-visible coverage-gap details for freshness lines. */
export function coverageGapDisplay(d: TelemetryFreshnessMetadata): CoverageGapDisplay | null {
  const count = d.coverage_gap_count ?? d.coverage_gaps?.length ?? 0
  if (count <= 0) return null

  const gap = latestCoverageGap(d)
  const reason = nonEmpty(gap?.stale_reason) ?? nonEmpty(d.stale_reason) ?? 'coverage_gap'
  const rawDetails: Array<[string, string | null]> = [
    ['producer', nonEmpty(gap?.producer) ?? nonEmpty(d.producer)],
    ['store', nonEmpty(gap?.durable_store) ?? nonEmpty(d.durable_store)],
    ['surface', nonEmpty(gap?.dashboard_surface) ?? nonEmpty(d.dashboard_surface)],
    ['trace', nonEmpty(gap?.trace_id)],
    ['error', nonEmpty(gap?.error)],
  ]
  const details = rawDetails
    .filter((entry): entry is [string, string] => entry[1] != null)
    .map(([label, value]) => `${label} ${value}`)

  return {
    count,
    summary: `coverage gaps ${count}: ${reason}`,
    details,
  }
}
