import { describe, it, expect } from 'vitest'
import {
  formatRatioPair,
  formatIndependentCounters,
} from './counter-format'

describe('counter-format', () => {
  describe('formatRatioPair', () => {
    it('renders numerator/denominator with a slash', () => {
      expect(formatRatioPair({ numerator: 3, denominator: 7 })).toBe('3/7')
    })

    it('renders 0/0 unchanged for empty ratio', () => {
      expect(formatRatioPair({ numerator: 0, denominator: 0 })).toBe('0/0')
    })

    it('renders equal values as N/N', () => {
      expect(formatRatioPair({ numerator: 5, denominator: 5 })).toBe('5/5')
    })
  })

  describe('formatIndependentCounters', () => {
    it('uses label N · label M form (no slash)', () => {
      const out = formatIndependentCounters({
        leftLabel: 'inj',
        leftValue: 909,
        rightLabel: 'flush',
        rightValue: 722,
      })
      expect(out).toBe('inj 909 · flush 722')
    })

    it('does not produce ratio-implying slash even when left > right', () => {
      // Regression: live keepers showed "mem 909/722" (126%). The new format
      // must never render as "N/M" for independent counters.
      const out = formatIndependentCounters({
        leftLabel: 'inj',
        leftValue: 909,
        rightLabel: 'flush',
        rightValue: 722,
      })
      expect(out).not.toMatch(/\d+\/\d+/)
    })

    it('handles zero values explicitly', () => {
      expect(
        formatIndependentCounters({
          leftLabel: 'ok',
          leftValue: 0,
          rightLabel: 'error',
          rightValue: 0,
        }),
      ).toBe('ok 0 · error 0')
    })
  })
})
