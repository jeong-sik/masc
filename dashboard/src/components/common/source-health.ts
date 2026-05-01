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
import type { TelemetryFreshnessMetadata } from '../../api/dashboard'

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
