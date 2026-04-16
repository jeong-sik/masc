import { describe, it, expect } from 'vitest'
import { formatPct, formatTokens } from './format-number'

describe('formatPct', () => {
  it('formats 0.5 as 50%', () => { expect(formatPct(0.5)).toBe('50%') })
  it('formats 0.0 as 0%', () => { expect(formatPct(0)).toBe('0%') })
  it('formats 1.0 as 100%', () => { expect(formatPct(1.0)).toBe('100%') })
  it('formats 0.856 as 86%', () => { expect(formatPct(0.856)).toBe('86%') })
  it('returns fallback for null', () => { expect(formatPct(null)).toBe('-') })
  it('returns fallback for undefined', () => { expect(formatPct(undefined)).toBe('-') })
  it('returns fallback for NaN', () => { expect(formatPct(NaN)).toBe('-') })
  it('returns fallback for Infinity', () => { expect(formatPct(Infinity)).toBe('-') })
  it('uses custom fallback', () => { expect(formatPct(null, 'N/A')).toBe('N/A') })
})

describe('formatTokens', () => {
  it('formats 0 as 0', () => { expect(formatTokens(0)).toBe('0') })
  it('formats small numbers as-is', () => { expect(formatTokens(42)).toBe('42') })
  it('formats thousands with K', () => { expect(formatTokens(4500)).toBe('4.5K') })
  it('formats 1000 as 1.0K', () => { expect(formatTokens(1000)).toBe('1.0K') })
  it('formats millions with M', () => { expect(formatTokens(1234567)).toBe('1.2M') })
  it('formats 1M as 1.0M', () => { expect(formatTokens(1_000_000)).toBe('1.0M') })
  it('returns dash for null', () => { expect(formatTokens(null)).toBe('-') })
  it('returns dash for undefined', () => { expect(formatTokens(undefined)).toBe('-') })
  it('returns dash for NaN', () => { expect(formatTokens(NaN)).toBe('-') })
  it('returns dash for Infinity', () => { expect(formatTokens(Infinity)).toBe('-') })
})
