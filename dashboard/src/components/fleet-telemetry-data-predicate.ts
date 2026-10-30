// Pure predicate split out from FleetTelemetryPanel's data-loading flow so
// the "do we have anything worth rendering?" decision can be unit-tested
// without driving the Preact render path.

type ExecutionTrustSnapshot = {
  total?: number | null
  entry_count?: number | null
  coverage_gap_count?: number | null
}

type ToolQualitySnapshot = {
  total: number
}

type TelemetrySummary = {
  total_entries: number
}

/**
 * Returns true when at least one of the fleet-telemetry source-of-truth
 * signals carries renderable data:
 *
 * - any keeper rows,
 * - execution-trust total / entry count,
 * - execution-trust coverage gap count (gap-only payloads are still
 *   actionable — they are the provenance signal the Execution Trust panel
 *   exists to surface when other sources are empty/unavailable),
 * - tool-quality total,
 * - telemetry-summary entry count.
 *
 * Mirrors the inline `hasAnyData` expression in `fleet-telemetry-panel.ts`
 * so the empty-state path stays aligned with what the panel actually
 * renders.
 */
export function hasFleetTelemetryData(input: {
  rowCount: number
  executionTrust: ExecutionTrustSnapshot | null | undefined
  toolQuality: ToolQualitySnapshot
  telemetrySummary: TelemetrySummary
}): boolean {
  const { rowCount, executionTrust, toolQuality, telemetrySummary } = input
  return (
    rowCount > 0
    || (executionTrust?.total ?? 0) > 0
    || (executionTrust?.entry_count ?? 0) > 0
    || (executionTrust?.coverage_gap_count ?? 0) > 0
    || toolQuality.total > 0
    || telemetrySummary.total_entries > 0
  )
}
