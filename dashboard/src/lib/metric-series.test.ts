import { describe, expect, it } from 'vitest'
import { normalizeKeepers } from '../keeper-store-normalize'
import { metricCoordinate, pairedTokenRatio, summarizeMetricSeries } from './metric-series'

describe('retained observation semantics', () => {
  it('keeps zero observed and splits missing measurements without inventing a sample', () => {
    const result = summarizeMetricSeries([
      { ts: 10, value: 0 }, { ts: 20, value: null }, { ts: 100, value: 0.002 },
    ])
    expect(result.observed).toBe(2)
    expect(result.missing).toBe(1)
    expect(result.segments).toEqual([[{ ts: 10, value: 0 }], [{ ts: 100, value: 0.002 }]])
    expect(result.minimum).toBe(0)
    expect(result.maximum).toBe(0.002)
  })

  it('uses elapsed timestamps and the actual positive metric maximum', () => {
    expect(metricCoordinate({ ts: 1, value: 0.001 }, [0, 100], 0.002))
      .toEqual({ x: 0.01, y: 0.5 })
    expect(metricCoordinate({ ts: 100, value: 0.002 }, [0, 100], 0.002))
      .toEqual({ x: 1, y: 1 })
  })

  it('preserves the producer normalizer unpriced sentinel as missing', () => {
    const [keeper] = normalizeKeepers([{ name: 'cost', status: 'active', metrics_series: [
      { ts_unix: 1, cost_usd: 0.001 }, { ts_unix: 2, cost_usd: null },
      { ts_unix: 3, cost_usd: 0.002 },
    ] }])
    const result = summarizeMetricSeries(keeper!.metrics_series!.map(p => ({ ts: p.ts, value: p.cost_usd })))
    expect(result.sum).toBeCloseTo(0.003)
    expect(result.observed).toBe(2)
    expect(result.missing).toBe(1)
    expect(result.segments).toHaveLength(2)
  })

  it('distinguishes an all-missing window, all-zero window, and missing latest value', () => {
    expect(summarizeMetricSeries([{ ts: 1, value: Number.NaN }]))
      .toMatchObject({ sum: null, latest: null, minimum: null, maximum: null, observed: 0 })
    expect(summarizeMetricSeries([{ ts: 1, value: 0 }]))
      .toMatchObject({ sum: 0, latest: 0, minimum: 0, maximum: 0, observed: 1 })
    expect(summarizeMetricSeries([{ ts: 1, value: 9 }, { ts: 2, value: undefined }]))
      .toMatchObject({ sum: 9, latest: null, observed: 1, missing: 1 })
  })

  it('orders values by producer timestamp without changing the source array', () => {
    const source = [{ ts: 2, value: null }, { ts: 1, value: 5 }]
    expect(summarizeMetricSeries(source).latest).toBeNull()
    expect(source.map(row => row.ts)).toEqual([2, 1])
  })

  it('never derives a usage ratio from hardware timings or unpaired counters', () => {
    const [keeper] = normalizeKeepers([{ name: 'tokens', status: 'active', metrics_series: [
      { ts_unix: 1, usage: { input_tokens: 10, output_tokens: 5 } },
      { ts_unix: 2, usage: { input_tokens: 999 }, inference_telemetry: { timings: { predicted_n: 20 } } },
    ] }])
    expect(pairedTokenRatio(keeper!.metrics_series!)).toEqual({ kind: 'observed', value: 2, samples: 1 })
  })

  it('separates paired zero output from missing output instead of dividing by an invented token', () => {
    const rows = (output: number | null) => normalizeKeepers([{ name: 'zero', status: 'active', metrics_series: [
      { ts_unix: 1, usage: { input_tokens: 10, output_tokens: output } },
    ] }])[0]!.metrics_series!
    expect(pairedTokenRatio(rows(0))).toEqual({ kind: 'zero_output', samples: 1 })
    expect(pairedTokenRatio(rows(null))).toEqual({ kind: 'unobserved' })
  })
})
