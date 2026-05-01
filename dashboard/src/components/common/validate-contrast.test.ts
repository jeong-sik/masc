// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { validateTokenContrast } from './validate-contrast'

describe('validateTokenContrast', () => {
  it('returns empty array when all colors are distinct', () => {
    const tokens = {
      'color-black': '#000000',
      'color-red': '#ff0000',
    }
    expect(validateTokenContrast(tokens)).toEqual([])
  })

  it('flags colors with deltaE below threshold', () => {
    const tokens = {
      'color-surface': '#0f172a',
      'color-surface-near': '#111827',
    }
    const violations = validateTokenContrast(tokens, 2)
    expect(violations.length).toBeGreaterThan(0)
    expect(violations[0].tokenA).toBeDefined()
    expect(violations[0].tokenB).toBeDefined()
    expect(violations[0].contrast).toBeLessThan(2)
  })

  it('respects custom threshold', () => {
    const tokens = {
      a: '#ffffff',
      b: '#f0f0f0',
    }
    const strict = validateTokenContrast(tokens, 20)
    expect(strict.length).toBeGreaterThan(0)

    const loose = validateTokenContrast(tokens, 0.01)
    expect(loose.length).toBe(0)
  })

  it('skips non-color values', () => {
    const tokens = {
      'bad-token': 'not-a-color',
      'good-token': '#ff0000',
    }
    expect(validateTokenContrast(tokens)).toEqual([])
  })
})
