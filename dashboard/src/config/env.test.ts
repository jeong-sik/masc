import { describe, it, expect } from 'vitest'
import { parseEnvInt } from './env'

describe('parseEnvInt', () => {
  it('returns fallback for nullish / empty values', () => {
    expect(parseEnvInt(undefined, 500)).toBe(500)
    expect(parseEnvInt(null, 500)).toBe(500)
    expect(parseEnvInt('', 500)).toBe(500)
  })

  it('returns fallback for non-numeric strings', () => {
    expect(parseEnvInt('abc', 500)).toBe(500)
    expect(parseEnvInt('NaN', 500)).toBe(500)
  })

  it('returns fallback for zero and negative values', () => {
    expect(parseEnvInt('0', 500)).toBe(500)
    expect(parseEnvInt('-1', 500)).toBe(500)
    expect(parseEnvInt('-100', 500)).toBe(500)
  })

  it('parses positive integers', () => {
    expect(parseEnvInt('1', 500)).toBe(1)
    expect(parseEnvInt('100', 500)).toBe(100)
    expect(parseEnvInt('2000', 500)).toBe(2000)
  })

  it('truncates floats to integers via parseInt semantics', () => {
    expect(parseEnvInt('1.5', 500)).toBe(1)
    expect(parseEnvInt('99.99', 500)).toBe(99)
  })

  it('ignores trailing garbage (parseInt lenient mode)', () => {
    expect(parseEnvInt('500abc', 100)).toBe(500)
    expect(parseEnvInt('1000 ', 0)).toBe(1000)
  })
})
