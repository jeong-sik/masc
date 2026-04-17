import { describe, it, expect } from 'vitest'
import { detectAnomalies, anomalySummary } from './anomaly-utils'
import type { ToolQualityHourlyPoint } from '../../api/dashboard'

function makePoint(success_rate: number, hour = '2026-04-17T00:00'): ToolQualityHourlyPoint {
  return { hour, calls: 10, success: Math.round(success_rate * 10), success_rate }
}

function makeWindowed(rates: number[]): Array<{ point: ToolQualityHourlyPoint; ts: number }> {
  return rates.map((r, i) => ({ point: makePoint(r), ts: i * 3600 }))
}

// ================================================================
// detectAnomalies
// ================================================================

describe('detectAnomalies', () => {
  it('returns no anomalies for < 3 points', () => {
    const data = makeWindowed([0.9, 0.85])
    const results = detectAnomalies(data)
    expect(results).toHaveLength(2)
    expect(results.every(r => !r.isAnomaly)).toBe(true)
    expect(results.every(r => r.zScore === 0)).toBe(true)
  })

  it('returns no anomalies for identical values', () => {
    const data = makeWindowed([0.9, 0.9, 0.9, 0.9])
    const results = detectAnomalies(data)
    expect(results.every(r => !r.isAnomaly)).toBe(true)
  })

  it('detects outlier with default threshold', () => {
    // 9 normal points + 1 extreme drop → z ≈ -3.0 for the outlier
    const data = makeWindowed([0.95, 0.97, 0.96, 0.98, 0.94, 0.99, 0.96, 0.97, 0.98, 0.0])
    const results = detectAnomalies(data)
    const anomalies = results.filter(r => r.isAnomaly)
    expect(anomalies.length).toBeGreaterThanOrEqual(1)
    expect(anomalies[0]!.point.success_rate).toBe(0.0)
  })

  it('respects custom threshold', () => {
    const data = makeWindowed([0.9, 0.91, 0.89, 0.85])
    // threshold=1.0 should catch more anomalies than default 2.0
    const strict = detectAnomalies(data, 1.0)
    const default_ = detectAnomalies(data, 2.0)
    expect(strict.filter(r => r.isAnomaly).length).toBeGreaterThanOrEqual(
      default_.filter(r => r.isAnomaly).length,
    )
  })

  it('preserves point data', () => {
    const data = makeWindowed([0.9, 0.85, 0.92])
    const results = detectAnomalies(data)
    expect(results[0]!.point.success_rate).toBe(0.9)
    expect(results[1]!.point.success_rate).toBe(0.85)
    expect(results[2]!.point.success_rate).toBe(0.92)
  })

  it('preserves timestamps', () => {
    const data = makeWindowed([0.9, 0.85, 0.92])
    const results = detectAnomalies(data)
    expect(results.map(r => r.ts)).toEqual([0, 3600, 7200])
  })

  it('returns empty array for empty input', () => {
    expect(detectAnomalies([])).toEqual([])
  })
})

// ================================================================
// anomalySummary
// ================================================================

describe('anomalySummary', () => {
  it('returns 0 count for empty results', () => {
    expect(anomalySummary([])).toEqual({ count: 0, worstDrop: null })
  })

  it('counts anomalies', () => {
    const results = [
      { point: makePoint(0.9), ts: 0, zScore: -0.5, isAnomaly: false },
      { point: makePoint(0.2), ts: 1, zScore: -3.0, isAnomaly: true },
      { point: makePoint(0.95), ts: 2, zScore: 0.3, isAnomaly: false },
    ]
    expect(anomalySummary(results).count).toBe(1)
  })

  it('returns worst drop by zScore', () => {
    const results = [
      { point: makePoint(0.3), ts: 1, zScore: -2.5, isAnomaly: true },
      { point: makePoint(0.1), ts: 2, zScore: -4.0, isAnomaly: true },
    ]
    const summary = anomalySummary(results)
    expect(summary.worstDrop!.zScore).toBe(-4.0)
    expect(summary.worstDrop!.point.success_rate).toBe(0.1)
  })

  it('returns null worstDrop when no drops', () => {
    const results = [
      { point: makePoint(0.95), ts: 0, zScore: 2.5, isAnomaly: true },
    ]
    expect(anomalySummary(results).worstDrop).toBeNull()
  })

  it('counts only anomalies', () => {
    const results = [
      { point: makePoint(0.9), ts: 0, zScore: -0.1, isAnomaly: false },
      { point: makePoint(0.9), ts: 1, zScore: 0.2, isAnomaly: false },
    ]
    expect(anomalySummary(results).count).toBe(0)
  })
})
