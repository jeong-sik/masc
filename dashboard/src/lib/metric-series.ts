import { isFiniteMetricValue } from './format-number'
import type { KeeperMetricPoint } from '../types'

/** Nonnegative measurements at the producer's Unix-second timestamps. */
export interface MetricReading {
  readonly ts: number
  readonly value: number | null | undefined
}
export interface ObservedMetricReading {
  readonly ts: number
  readonly value: number
}

export function summarizeMetricSeries(readings: readonly MetricReading[]) {
  const rows = [...readings].sort((a, b) => a.ts - b.ts).map(row => ({ ts: row.ts,
    value: isFiniteMetricValue(row.value) && row.value >= 0 ? row.value : null }))
  const segments: ObservedMetricReading[][] = []
  let segment: ObservedMetricReading[] = []
  let minimum: number | null = null
  let maximum: number | null = null
  let sum = 0, observed = 0
  for (const row of rows) {
    if (row.value === null) {
      if (segment.length > 0) segments.push(segment)
      segment = []
      continue
    }
    segment.push({ ts: row.ts, value: row.value })
    minimum = minimum === null ? row.value : Math.min(minimum, row.value)
    maximum = maximum === null ? row.value : Math.max(maximum, row.value)
    sum += row.value
    observed += 1
  }
  if (segment.length > 0) segments.push(segment)
  return { rows, segments, observed, missing: rows.length - observed, minimum, maximum,
    sum: observed > 0 ? sum : null, latest: rows[rows.length - 1]?.value ?? null }
}

/** Numeric chart coordinates; absent readings never acquire a coordinate. */
export function metricCoordinate(reading: ObservedMetricReading,
  domain: readonly [number, number], maximum: number) {
  const span = domain[1] - domain[0]
  return { x: span > 0 ? (reading.ts - domain[0]) / span : 0.5,
    y: maximum > 0 ? reading.value / maximum : 0 }
}

export type TokenRatio =
  | { readonly kind: 'observed'; readonly value: number; readonly samples: number }
  | { readonly kind: 'zero_output'; readonly samples: number }
  | { readonly kind: 'unobserved' }

/** Compare paired canonical usage counters, never hardware timing counters. */
export function pairedTokenRatio(points: readonly KeeperMetricPoint[]): TokenRatio {
  let input = 0, output = 0, samples = 0
  for (const point of points) {
    if (!isFiniteMetricValue(point.input_tokens) || point.input_tokens < 0
      || !isFiniteMetricValue(point.output_tokens) || point.output_tokens < 0) continue
    input += point.input_tokens
    output += point.output_tokens
    samples += 1
  }
  if (samples === 0) return { kind: 'unobserved' }
  return output > 0 ? { kind: 'observed', value: input / output, samples }
    : { kind: 'zero_output', samples }
}
