// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  relativeLuminance,
  contrastRatio,
  requiredRatio,
  validateWCAGContrast,
} from './wcag-contrast'

describe('relativeLuminance', () => {
  it('returns 0 for black', () => {
    expect(relativeLuminance('#000000')).toBe(0)
  })

  it('returns 1 for white', () => {
    expect(relativeLuminance('#ffffff')).toBe(1)
  })

  it('handles 3-digit hex', () => {
    expect(relativeLuminance('#fff')).toBe(1)
    expect(relativeLuminance('#000')).toBe(0)
  })

  it('handles 8-digit hex (ignores alpha)', () => {
    expect(relativeLuminance('#ffffffff')).toBe(1)
  })

  it('returns null for non-color', () => {
    expect(relativeLuminance('not-a-color')).toBeNull()
  })
})

describe('contrastRatio', () => {
  it('black vs white is 21:1', () => {
    expect(contrastRatio('#000000', '#ffffff')).toBeCloseTo(21, 1)
  })

  it('same color is 1:1', () => {
    expect(contrastRatio('#777777', '#777777')).toBeCloseTo(1, 1)
  })

  it('returns null for invalid colors', () => {
    expect(contrastRatio('bad', '#fff')).toBeNull()
  })
})

describe('requiredRatio', () => {
  it('AA normal text is 4.5', () => {
    expect(requiredRatio('AA', false)).toBe(4.5)
  })

  it('AA large text is 3', () => {
    expect(requiredRatio('AA', true)).toBe(3)
  })

  it('AAA normal text is 7', () => {
    expect(requiredRatio('AAA', false)).toBe(7)
  })

  it('AAA large text is 4.5', () => {
    expect(requiredRatio('AAA', true)).toBe(4.5)
  })
})

describe('validateWCAGContrast', () => {
  it('returns empty when no tokens', () => {
    expect(validateWCAGContrast({})).toEqual([])
  })

  it('flags pairs below AA threshold', () => {
    const tokens = {
      'color-surface': '#ffffff',
      'color-text': '#cccccc',
    }
    const violations = validateWCAGContrast(tokens, 'AA')
    expect(violations.length).toBeGreaterThan(0)
    expect(violations[0].ratio).toBeLessThan(4.5)
    expect(violations[0].required).toBe(4.5)
  })

  it('accepts pairs above AA threshold', () => {
    const tokens = {
      'color-surface': '#ffffff',
      'color-text': '#000000',
    }
    expect(validateWCAGContrast(tokens, 'AA')).toEqual([])
  })

  it('uses stricter AAA threshold', () => {
    const tokens = {
      a: '#ffffff',
      b: '#767676',
    }
    const aa = validateWCAGContrast(tokens, 'AA')
    expect(aa.length).toBe(0)

    const aaa = validateWCAGContrast(tokens, 'AAA')
    expect(aaa.length).toBeGreaterThan(0)
    expect(aaa[0].required).toBe(7)
  })

  it('skips non-color values', () => {
    const tokens = {
      good: '#000000',
      bad: 'not-a-color',
    }
    expect(validateWCAGContrast(tokens)).toEqual([])
  })

  it('respects largeText flag for AA', () => {
    const tokens = {
      a: '#ffffff',
      b: '#949494',
    }
    const normal = validateWCAGContrast(tokens, 'AA', false)
    expect(normal.length).toBeGreaterThan(0)

    const large = validateWCAGContrast(tokens, 'AA', true)
    expect(large.length).toBe(0)
  })
})
