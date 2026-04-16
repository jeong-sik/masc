import { describe, it, expect } from 'vitest'
import { trimText, truncate } from './truncate'

describe('trimText', () => {
  it('returns null for null', () => { expect(trimText(null)).toBeNull() })
  it('returns null for undefined', () => { expect(trimText(undefined)).toBeNull() })
  it('returns null for empty', () => { expect(trimText('')).toBeNull() })
  it('returns null for whitespace only', () => { expect(trimText('   ')).toBeNull() })
  it('passes short text through', () => { expect(trimText('hello')).toBe('hello') })
  it('collapses whitespace', () => { expect(trimText('hello   world')).toBe('hello world') })
  it('trims leading/trailing whitespace', () => { expect(trimText('  hello  ')).toBe('hello') })
  it('truncates long text with ellipsis', () => {
    const long = 'a'.repeat(200)
    const result = trimText(long, 120)
    expect(result!.length).toBeLessThanOrEqual(120)
    expect(result).toContain('…')
  })
  it('respects custom max', () => {
    expect(trimText('abcdefghij', 5)).toBe('abcd…')
  })
})

describe('truncate', () => {
  it('passes short text through', () => { expect(truncate('hello')).toBe('hello') })
  it('truncates long text', () => {
    const result = truncate('a'.repeat(300))
    expect(result.length).toBeLessThan(300)
    expect(result).toContain('…')
  })
  it('respects custom limit', () => {
    expect(truncate('abcdefghij', 5)).toBe('abcd…')
  })
  it('keeps text at exact limit', () => {
    expect(truncate('abcde', 5)).toBe('abcde')
  })
})
