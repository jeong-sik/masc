import { describe, it, expect } from 'vitest'
import { supportHeatBucket, impactBucket, riskBucket, computeCategoryCoverage, scoreBucket, applicabilityCellClass } from './data'
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

describe('scoreBucket', () => {
  it.each([
    ['88.58', 'z4'],
    ['75.0', 'z4'],
    ['72.38', 'z3'],
    ['65.0', 'z3'],
    ['59.06', 'z2'],
    ['55.0', 'z2'],
    ['52.15', 'z1'],
    ['45.0', 'z1'],
    ['38.37', 'z0'],
    ['14.12', 'z0'],
  ])('maps %s → %s', (input, expected) => {
    expect(scoreBucket(input)).toBe(expected)
  })
})

describe('applicabilityCellClass', () => {
  it.each([
    ['full', 'z4'],
    ['partial', 'z2'],
    ['none', 'z0'],
    ['na', 'z0'],
  ] as const)('maps %s → %s', (input, expected) => {
    expect(applicabilityCellClass(input)).toBe(expected)
  })
})
