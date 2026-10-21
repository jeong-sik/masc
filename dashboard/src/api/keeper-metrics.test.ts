import { describe, expect, it } from 'vitest'
import { parseKeeperMetrics } from './keeper-metrics'

const envelope = () => ({ keeper: 'selected', series: [], scanned_rows: 0, skipped_rows: 0, limit: 120 })

describe('selected Keeper metrics delivery', () => {
  it('preserves current usage, zero latency and missing cost from a selected store projection', () => {
    const result = parseKeeperMetrics({ ...envelope(), scanned_rows: 2, skipped_rows: 1, series: [
      { ts_unix: 100, latency_ms: 0, usage: { input_tokens: 12, output_tokens: 0 }, cost_usd: null },
    ] }, 'selected')
    expect(result.series[0]).toMatchObject({ ts: 100, latency_ms: 0, input_tokens: 12, output_tokens: 0 })
    expect(Number.isNaN(result.series[0]?.cost_usd)).toBe(true)
    expect(result.skippedRows).toBe(1)
  })

  it('refuses another Keeper or missing series rather than treating either as an empty history', () => {
    expect(() => parseKeeperMetrics(envelope(), 'other')).toThrow()
    expect(() => parseKeeperMetrics({ ...envelope(), series: undefined }, 'selected')).toThrow()
  })

  it('refuses corrupt timestamps and impossible coverage', () => {
    expect(() => parseKeeperMetrics({ ...envelope(), scanned_rows: 1, series: [{ latency_ms: 1 }] }, 'selected')).toThrow()
    expect(() => parseKeeperMetrics({ ...envelope(), skipped_rows: 1 }, 'selected')).toThrow()
  })
})
