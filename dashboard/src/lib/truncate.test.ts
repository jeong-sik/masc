// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { trimText, truncate } from './truncate'

describe('trimText', () => {
  it('returns null for empty string', () => {
    expect(trimText('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(trimText('   ')).toBeNull()
  })

  it('returns null for null input', () => {
    expect(trimText(null)).toBeNull()
  })

  it('returns null for undefined input', () => {
    expect(trimText(undefined)).toBeNull()
  })

  it('collapses whitespace', () => {
    expect(trimText('a    b')).toBe('a b')
  })

  it('trims leading and trailing whitespace', () => {
    expect(trimText('  hello  ')).toBe('hello')
  })

  it('returns short text unchanged', () => {
    expect(trimText('hello', 10)).toBe('hello')
  })

  it('truncates long text with ellipsis', () => {
    expect(trimText('hello world', 5)).toBe('hell…')
  })
})

describe('truncate', () => {
  it('returns original if within limit', () => {
    expect(truncate('hi', 10)).toBe('hi')
  })

  it('truncates with ellipsis when over limit', () => {
    expect(truncate('hello', 4)).toBe('hel…')
  })

  it('handles exact limit', () => {
    expect(truncate('hello', 5)).toBe('hello')
  })

  it('uses default limit', () => {
    const long = 'a'.repeat(261)
    expect(truncate(long).length).toBeLessThan(long.length)
    expect(truncate(long).endsWith('…')).toBe(true)
  })
})
