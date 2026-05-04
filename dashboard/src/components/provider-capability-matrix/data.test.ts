import { describe, it, expect } from 'vitest'
import { supportHeatBucket, impactBucket, riskBucket, computeCategoryCoverage } from './data'
import type { FeatureSupport, WiringImpact, RiskLevel } from './data'

describe('supportHeatBucket', () => {
  it.each([
    ['●', 'z4'],
    ['◐', 'z2'],
    ['○', 'z1'],
    ['—', 'z0'],
  ] as [FeatureSupport, string][])('maps %s → %s', (input, expected) => {
    expect(supportHeatBucket(input)).toBe(expected)
  })
})

describe('impactBucket', () => {
  it.each([
    ['high', 'z4'],
    ['medium', 'z2'],
    ['low', 'z1'],
    ['correct', 'z0'],
  ] as [WiringImpact, string][])('maps %s → %s', (input, expected) => {
    expect(impactBucket(input)).toBe(expected)
  })
})

describe('riskBucket', () => {
  it.each([
    ['C', 'z4'],
    ['H', 'z3'],
    ['M', 'z2'],
    ['L', 'z1'],
  ] as [RiskLevel, string][])('maps %s → %s', (input, expected) => {
    expect(riskBucket(input)).toBe(expected)
  })
})

describe('computeCategoryCoverage', () => {
  it('returns one entry per feature category', () => {
    const coverage = computeCategoryCoverage()
    expect(coverage.length).toBe(6)
  })

  it('all entries have valid percentages (0-100)', () => {
    for (const c of computeCategoryCoverage()) {
      expect(c.pct).toBeGreaterThanOrEqual(0)
      expect(c.pct).toBeLessThanOrEqual(100)
      expect(c.total).toBeGreaterThan(0)
    }
  })

  it('tool-use category has >50% coverage', () => {
    const toolUse = computeCategoryCoverage().find(c => c.id === 'tool-use')
    expect(toolUse).toBeDefined()
    expect(toolUse!.pct).toBeGreaterThan(50)
  })
})
