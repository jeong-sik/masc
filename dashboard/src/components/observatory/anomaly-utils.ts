// Observatory anomaly detection (RFC-MASC-006 Phase 3a)
//
// Compute z-scores over hourly_trend success_rate values.
// Points with |z| > threshold are flagged as anomalies.
// Minimum 3 data points required for meaningful statistics.

import type { ToolQualityHourlyPoint } from '../../api/dashboard'

export interface AnomalyResult {
  point: ToolQualityHourlyPoint
  ts: number
  zScore: number
  isAnomaly: boolean
}

const DEFAULT_THRESHOLD = 2.0

export interface AnomalySummary {
  count: number
  worstDrop: AnomalyResult | null
}

export function anomalySummary(results: AnomalyResult[]): AnomalySummary {
  const anomalies = results.filter(r => r.isAnomaly)
  const drops = anomalies.filter(r => r.zScore < 0)
  const worstDrop = drops.length > 0
    ? drops.reduce((worst, cur) => cur.zScore < worst.zScore ? cur : worst)
    : null
  return { count: anomalies.length, worstDrop }
}

export function detectAnomalies(
  windowed: Array<{ point: ToolQualityHourlyPoint; ts: number }>,
  threshold: number = DEFAULT_THRESHOLD,
): AnomalyResult[] {
  if (windowed.length < 3) {
    return windowed.map(w => ({
      point: w.point,
      ts: w.ts,
      zScore: 0,
      isAnomaly: false,
    }))
  }

  const rates = windowed.map(w => w.point.success_rate)
  const mean = rates.reduce((a, b) => a + b, 0) / rates.length
  const variance = rates.reduce((sum, r) => sum + (r - mean) ** 2, 0) / rates.length
  const stddev = Math.sqrt(variance)

  if (stddev === 0) {
    return windowed.map(w => ({
      point: w.point,
      ts: w.ts,
      zScore: 0,
      isAnomaly: false,
    }))
  }

  return windowed.map(w => {
    const zScore = (w.point.success_rate - mean) / stddev
    return {
      point: w.point,
      ts: w.ts,
      zScore,
      isAnomaly: Math.abs(zScore) > threshold,
    }
  })
}

