import { describe, it, expect } from 'vitest'
import { parseJsonLikeData } from './json-viewer'

describe('parseJsonLikeData', () => {
  it('returns non-string values unchanged', () => {
    expect(parseJsonLikeData(42)).toBe(42)
    expect(parseJsonLikeData(true)).toBe(true)
    expect(parseJsonLikeData(null)).toBe(null)
    expect(parseJsonLikeData(undefined)).toBe(undefined)
    expect(parseJsonLikeData([1, 2])).toEqual([1, 2])
  })

  it('returns plain string unchanged (not JSON-like)', () => {
    expect(parseJsonLikeData('hello world')).toBe('hello world')
  })

  it('returns string without JSON prefix unchanged', () => {
    expect(parseJsonLikeData('foo: bar')).toBe('foo: bar')
  })

  it('parses valid JSON object string', () => {
    const result = parseJsonLikeData('{"key":"value"}')
    expect(result).toEqual({ key: 'value' })
  })

  it('parses valid JSON array string', () => {
    const result = parseJsonLikeData('[1,2,3]')
    expect(result).toEqual([1, 2, 3])
  })

  it('parses JSON with leading whitespace', () => {
    const result = parseJsonLikeData('  {"a":1}')
    expect(result).toEqual({ a: 1 })
  })

  it('returns original string for invalid JSON starting with {', () => {
    expect(parseJsonLikeData('{not valid json}')).toBe('{not valid json}')
  })

  it('returns original string for invalid JSON starting with [', () => {
    expect(parseJsonLikeData('[broken')).toBe('[broken')
  })

  it('parses nested JSON', () => {
    const input = '{"outer":{"inner":42}}'
    expect(parseJsonLikeData(input)).toEqual({ outer: { inner: 42 } })
  })

  it('returns empty string unchanged', () => {
    expect(parseJsonLikeData('')).toBe('')
  })
})
