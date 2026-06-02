import { describe, expect, it } from 'vitest'

import { hasFleetTelemetryData } from './fleet-telemetry-data-predicate'

const emptyToolQuality = { total: 0 }
const emptyTelemetrySummary = { total_entries: 0 }

describe('hasFleetTelemetryData', () => {
  it('returns false when every source reports nothing', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: null,
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(false)
  })

  it('returns true when only execution-trust coverage_gap_count > 0', () => {
    // Regression for #15107: gap-only payloads (total=0, entry_count=0,
    // coverage_gap_count>0) were misclassified as empty and hid the
    // Execution Trust panel that exists to surface that gap.
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: { total: 0, entry_count: 0, coverage_gap_count: 1 },
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(true)
  })

  it('returns true when there are any keeper rows', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 3,
        executionTrust: null,
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(true)
  })

  it('returns true when execution-trust total > 0', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: { total: 5 },
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(true)
  })

  it('returns true when execution-trust entry_count > 0', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: { entry_count: 2 },
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(true)
  })

  it('returns true when tool-quality total > 0', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: null,
        toolQuality: { total: 1 },
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(true)
  })

  it('returns true when telemetry-summary entries > 0', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: null,
        toolQuality: emptyToolQuality,
        telemetrySummary: { total_entries: 9 },
      }),
    ).toBe(true)
  })

  it('treats null/undefined execution-trust fields as zero', () => {
    expect(
      hasFleetTelemetryData({
        rowCount: 0,
        executionTrust: { total: null, entry_count: undefined, coverage_gap_count: null },
        toolQuality: emptyToolQuality,
        telemetrySummary: emptyTelemetrySummary,
      }),
    ).toBe(false)
  })
})
