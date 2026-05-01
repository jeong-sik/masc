// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { formatPct, formatTokens } from './format-number'

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
