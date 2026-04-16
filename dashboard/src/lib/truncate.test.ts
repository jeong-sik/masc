import { describe, it, expect } from 'vitest'
import { trimText, truncate } from './truncate'

describe('trimText', () => {
  it('returns null for null', () => {
    expect(trimText(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(trimText(undefined)).toBeNull()
  })

  it('returns null for empty string', () => {
    expect(trimText('')).toBeNull()
  })

  it('returns null for whitespace only', () => {
    expect(trimText('   ')).toBeNull()
  })

  it('collapses whitespace', () => {
    expect(trimText('hello   world')).toBe('hello world')
  })

  it('trims leading/trailing whitespace', () => {
    expect(trimText('  hello  ')).toBe('hello')
  })

  it('truncates long text with ellipsis', () => {
    const long = 'a'.repeat(300)
    const result = trimText(long)
    expect(result).not.toBeNull()
    expect(result!.endsWith('…')).toBe(true)
    expect(result!.length).toBeLessThan(long.length)
  })

  it('keeps short text as-is', () => {
    expect(trimText('short')).toBe('short')
  })
})

describe('truncate', () => {
  it('keeps short string as-is', () => {
    expect(truncate('hello')).toBe('hello')
  })

  it('truncates at default limit', () => {
    const long = 'a'.repeat(300)
    const result = truncate(long)
    expect(result.endsWith('…')).toBe(true)
    expect(result.length).toBeLessThan(long.length)
  })

  it('respects custom limit', () => {
    expect(truncate('abcdefghij', 5)).toBe('abcd…')
  })

  it('keeps string exactly at limit', () => {
    expect(truncate('abcde', 5)).toBe('abcde')
  })
})
