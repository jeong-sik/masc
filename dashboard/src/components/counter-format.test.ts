import { describe, it, expect } from 'vitest'
import { formatRatioPair } from './counter-format'

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
})
