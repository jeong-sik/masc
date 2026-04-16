import { describe, it, expect } from 'vitest'
import { formatPct, formatTokens } from './format-number'

describe('formatPct', () => {
  it('formats 0–1 ratio as percentage', () => {
    expect(formatPct(0)).toBe('0%')
    expect(formatPct(0.5)).toBe('50%')
    expect(formatPct(1)).toBe('100%')
  })

  it('rounds to nearest percent', () => {
    expect(formatPct(0.856)).toBe('86%')
    expect(formatPct(0.854)).toBe('85%')
  })

  it('returns fallback for null', () => {
    expect(formatPct(null)).toBe('-')
  })

  it('returns fallback for undefined', () => {
    expect(formatPct(undefined)).toBe('-')
  })

  it('returns fallback for NaN', () => {
    expect(formatPct(NaN)).toBe('-')
  })

  it('uses custom fallback', () => {
    expect(formatPct(null, 'N/A')).toBe('N/A')
  })
})

describe('formatTokens', () => {
  it('returns dash for null', () => {
    expect(formatTokens(null)).toBe('-')
  })

  it('returns dash for undefined', () => {
    expect(formatTokens(undefined)).toBe('-')
  })

  it('returns 0 for zero', () => {
    expect(formatTokens(0)).toBe('0')
  })

  it('formats small numbers as-is', () => {
    expect(formatTokens(42)).toBe('42')
    expect(formatTokens(999)).toBe('999')
  })

  it('abbreviates thousands', () => {
    expect(formatTokens(1500)).toBe('1.5K')
    expect(formatTokens(4500)).toBe('4.5K')
  })

  it('abbreviates millions', () => {
    expect(formatTokens(1_500_000)).toBe('1.5M')
    expect(formatTokens(2_345_678)).toBe('2.3M')
  })

  it('returns dash for NaN', () => {
    expect(formatTokens(NaN)).toBe('-')
  })
})
