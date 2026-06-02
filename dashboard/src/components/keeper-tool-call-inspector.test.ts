import { describe, it, expect } from 'vitest'
import { formatInput } from './keeper-tool-call-inspector'

describe('formatInput', () => {
  it('returns dash for null', () => {
    expect(formatInput(null)).toBe('-')
  })

  it('returns dash for undefined', () => {
    expect(formatInput(undefined)).toBe('-')
  })

  it('returns string as-is', () => {
    expect(formatInput('hello world')).toBe('hello world')
  })

  it('returns empty string as-is', () => {
    expect(formatInput('')).toBe('')
  })

  it('JSON-stringifies objects with pretty print', () => {
    const result = formatInput({ key: 'value' })
    expect(result).toBe('{\n  "key": "value"\n}')
  })

  it('JSON-stringifies arrays', () => {
    const result = formatInput([1, 2, 3])
    expect(result).toBe('[\n  1,\n  2,\n  3\n]')
  })

  it('JSON-stringifies numbers', () => {
    expect(formatInput(42)).toBe('42')
  })

  it('JSON-stringifies booleans', () => {
    expect(formatInput(true)).toBe('true')
    expect(formatInput(false)).toBe('false')
  })

  it('handles circular references gracefully via String fallback', () => {
    const obj: Record<string, unknown> = {}
    obj.self = obj
    // JSON.stringify throws on circular, falls back to String()
    const result = formatInput(obj)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })
})
