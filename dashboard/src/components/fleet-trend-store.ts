// Fleet Trend Store — in-memory ring buffer for per-keeper metric snapshots.
// Captures 10 snapshots (at 30s refresh = 5 minutes of history) and computes
// directional trends (up/down/flat) with delta values and sparkline data.

import type { FleetRow } from './fleet-telemetry-utils'

const RING_CAPACITY = 10
const MIN_SAMPLES_FOR_TREND = 3
const FLAT_THRESHOLD = 0.02

export type MetricKey = 'context_ratio' | 'tool_success_pct' | 'tool_calls' | 'last_latency_ms'

export type TrendDirection = 'up' | 'down' | 'flat'

export interface TrendInfo {
  direction: TrendDirection
  delta: number
  deltaPercent: number
  values: number[]
}

const TRACKED_METRICS: MetricKey[] = ['context_ratio', 'tool_success_pct', 'tool_calls', 'last_latency_ms']

const store = new Map<string, number[]>()

function storeKey(keeperName: string, metric: MetricKey): string {
  return `${keeperName}:${metric}`
}

function metricValue(row: FleetRow, metric: MetricKey): number | null {
  switch (metric) {
    case 'context_ratio': return row.context_ratio
    case 'tool_success_pct': return row.tool_success_pct
    case 'tool_calls': return row.tool_calls
    case 'last_latency_ms': return row.last_latency_ms
  }
}

function average(values: number[]): number {
  if (values.length === 0) return 0
  let sum = 0
  for (const v of values) sum += v
  return sum / values.length
}

export function pushSnapshot(rows: FleetRow[]): void {
  for (const row of rows) {
    for (const metric of TRACKED_METRICS) {
      const value = metricValue(row, metric)
      if (value == null || !Number.isFinite(value)) continue
      const key = storeKey(row.name, metric)
      let ring = store.get(key)
      if (!ring) {
        ring = []
        store.set(key, ring)
      }
      ring.push(value)
      if (ring.length > RING_CAPACITY) {
        ring.splice(0, ring.length - RING_CAPACITY)
      }
    }
  }
}

export function getTrend(keeperName: string, metric: MetricKey): TrendInfo | null {
  const key = storeKey(keeperName, metric)
  const ring = store.get(key)
  if (!ring || ring.length < MIN_SAMPLES_FOR_TREND) return null

  const recentSlice = ring.slice(-MIN_SAMPLES_FOR_TREND)
  const oldestSlice = ring.slice(0, MIN_SAMPLES_FOR_TREND)
  const recentAvg = average(recentSlice)
  const oldestAvg = average(oldestSlice)
  const delta = recentAvg - oldestAvg
  const deltaPercent = oldestAvg !== 0 ? (delta / Math.abs(oldestAvg)) * 100 : 0

  let direction: TrendDirection
  if (oldestAvg === 0 && recentAvg === 0) {
    direction = 'flat'
  } else if (Math.abs(deltaPercent) < FLAT_THRESHOLD * 100) {
    direction = 'flat'
  } else {
    direction = delta > 0 ? 'up' : 'down'
  }

  return { direction, delta, deltaPercent, values: [...ring] }
}

export function resetTrendStore(): void {
  store.clear()
}
