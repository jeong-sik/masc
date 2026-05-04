import { describe, it, expect } from 'vitest'
import { supportHeatBucket } from './data'
import type { FeatureSupport } from './data'

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
