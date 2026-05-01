// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  contrastRatio,
  relativeLuminance,
  requiredRatio,
  validateWCAGContrast,
} from './wcag-contrast'

describe('relativeLuminance', () => {
  it('returns null for invalid hex', () => {
    expect(relativeLuminance('not-a-color')).toBeNull()
    expect(relativeLuminance('#zzzzzz')).toBeNull()
  })

  it('calculates for 3-digit hex', () => {
    expect(relativeLuminance('#fff')).toBeCloseTo(1, 3)
    expect(relativeLuminance('#000')).toBeCloseTo(0, 3)
  })

  it('calculates for 6-digit hex', () => {
    expect(relativeLuminance('#ffffff')).toBeCloseTo(1, 3)
    expect(relativeLuminance('#000000')).toBeCloseTo(0, 3)
  })

  it('calculates for 8-digit hex (ignores alpha)', () => {
    expect(relativeLuminance('#ffffffff')).toBeCloseTo(1, 3)
  })
})

describe('contrastRatio', () => {
  it('returns null for invalid colors', () => {
    expect(contrastRatio('bad', '#fff')).toBeNull()
  })

  it('returns 21:1 for black vs white', () => {
    expect(contrastRatio('#000000', '#ffffff')).toBeCloseTo(21, 1)
  })

  it('returns 1:1 for same color', () => {
    expect(contrastRatio('#777777', '#777777')).toBeCloseTo(1, 1)
  })

  it('is symmetric', () => {
    const a = contrastRatio('#000000', '#ffffff')
    const b = contrastRatio('#ffffff', '#000000')
    expect(a).toBe(b)
  })
})

describe('requiredRatio', () => {
  it('returns 4.5 for AA normal text', () => {
    expect(requiredRatio('AA', false)).toBe(4.5)
  })

  it('returns 3 for AA large text', () => {
    expect(requiredRatio('AA', true)).toBe(3)
  })

  it('returns 7 for AAA normal text', () => {
    expect(requiredRatio('AAA', false)).toBe(7)
  })

  it('returns 4.5 for AAA large text', () => {
    expect(requiredRatio('AAA', true)).toBe(4.5)
  })
})

describe('validateWCAGContrast', () => {
  it('returns empty array for single token', () => {
    expect(validateWCAGContrast({ a: '#000' })).toEqual([])
  })

  it('finds violation for low-contrast pair', () => {
    const tokens = { a: '#eeeeee', b: '#ffffff' }
    const v = validateWCAGContrast(tokens, 'AA')
    expect(v.length).toBeGreaterThan(0)
    expect(v[0]).toHaveProperty('tokenA')
    expect(v[0]).toHaveProperty('tokenB')
    expect(v[0]).toHaveProperty('ratio')
    expect(v[0]).toHaveProperty('required')
  })

  it('returns empty for high-contrast pair', () => {
    const tokens = { a: '#000000', b: '#ffffff' }
    expect(validateWCAGContrast(tokens, 'AA')).toEqual([])
  })

  it('checks all combinations', () => {
    const tokens = { a: '#000', b: '#fff', c: '#777' }
    const v = validateWCAGContrast(tokens, 'AA')
    expect(v.length).toBeGreaterThan(0)
  })
})
