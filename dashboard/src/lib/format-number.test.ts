// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { formatPct, formatPct1, formatTokens, formatNumber, formatCost } from './format-number'

describe('formatPct', () => {
  it('formats 0 as 0%', () => {
    expect(formatPct(0)).toBe('0%')
  })

  it('formats 1 as 100%', () => {
    expect(formatPct(1)).toBe('100%')
  })

  it('formats 0.5 as 50%', () => {
    expect(formatPct(0.5)).toBe('50%')
  })

  it('rounds to nearest integer', () => {
    expect(formatPct(0.333)).toBe('33%')
    expect(formatPct(0.666)).toBe('67%')
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

  it('returns fallback for Infinity', () => {
    expect(formatPct(Infinity)).toBe('-')
  })

  it('uses custom fallback', () => {
    expect(formatPct(null, 'N/A')).toBe('N/A')
  })
})

describe('formatPct1', () => {
  it('formats 0 as 0.0%', () => {
    expect(formatPct1(0)).toBe('0.0%')
  })

  it('formats 1 as 100.0%', () => {
    expect(formatPct1(1)).toBe('100.0%')
  })

  it('formats 0.5 as 50.0%', () => {
    expect(formatPct1(0.5)).toBe('50.0%')
  })

  it('preserves 1 decimal', () => {
    expect(formatPct1(0.333)).toBe('33.3%')
    expect(formatPct1(0.666)).toBe('66.6%')
  })

  it('returns fallback for null', () => {
    expect(formatPct1(null)).toBe('-')
  })

  it('returns fallback for undefined', () => {
    expect(formatPct1(undefined)).toBe('-')
  })

  it('returns fallback for NaN', () => {
    expect(formatPct1(NaN)).toBe('-')
  })

  it('returns fallback for Infinity', () => {
    expect(formatPct1(Infinity)).toBe('-')
  })

  it('uses custom fallback', () => {
    expect(formatPct1(null, '--')).toBe('--')
  })
})

describe('formatTokens', () => {
  it('returns 0 for zero', () => {
    expect(formatTokens(0)).toBe('0')
  })

  it('returns string for small numbers', () => {
    expect(formatTokens(123)).toBe('123')
  })

  it('abbreviates thousands with K', () => {
    expect(formatTokens(4_500)).toBe('4.5K')
    expect(formatTokens(1_000)).toBe('1.0K')
  })

  it('abbreviates millions with M', () => {
    expect(formatTokens(1_234_567)).toBe('1.2M')
    expect(formatTokens(1_000_000)).toBe('1.0M')
  })

  it('returns dash for null', () => {
    expect(formatTokens(null)).toBe('-')
  })

  it('returns dash for undefined', () => {
    expect(formatTokens(undefined)).toBe('-')
  })

  it('returns dash for NaN', () => {
    expect(formatTokens(NaN)).toBe('-')
  })
})

describe('formatNumber', () => {
  it('returns -- for undefined', () => {
    expect(formatNumber(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(formatNumber(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(formatNumber(NaN)).toBe('--')
  })

  it('formats integer with locale grouping', () => {
    const result = formatNumber(1234)
    expect(result).toContain('1,234')
  })

  it('formats with custom digits', () => {
    const result = formatNumber(1234.567, 2)
    expect(result).toContain('1,234.57')
  })

  it('uses custom fallback', () => {
    expect(formatNumber(null, 0, 'N/A')).toBe('N/A')
  })
})

describe('formatCost', () => {
  it('returns -- for undefined', () => {
    expect(formatCost(undefined)).toBe('--')
  })

  it('returns -- for null', () => {
    expect(formatCost(null)).toBe('--')
  })

  it('returns -- for NaN', () => {
    expect(formatCost(NaN)).toBe('--')
  })

  it('returns $0 for zero', () => {
    expect(formatCost(0)).toBe('$0')
  })

  it('formats sub-cent values with 4 decimals', () => {
    expect(formatCost(0.005)).toBe('$0.0050')
  })

  it('formats regular values with 2 decimals', () => {
    expect(formatCost(1.5)).toBe('$1.50')
  })

  it('formats large values with 2 decimals', () => {
    expect(formatCost(123.456)).toBe('$123.46')
  })

  it('uses custom fallback', () => {
    expect(formatCost(null, 'N/A')).toBe('N/A')
  })
})
