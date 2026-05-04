import { describe, it, expect } from 'vitest'
import { supportHeatBucket, impactBucket, riskBucket } from './data'
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
