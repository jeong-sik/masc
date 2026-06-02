import { describe, it, expect } from 'vitest'
import {
  isRecord,
  asString,
  asNumber,
  asBoolean,
  asInt,
  asStringArray,
  asRecordArray,
  asNullableString,
  asStringList,
  extractArray,
  toIsoTimestamp,
} from './normalize'

// ================================================================
// isRecord
// ================================================================

describe('isRecord', () => {
  it('returns true for plain objects', () => {
    expect(isRecord({})).toBe(true)
    expect(isRecord({ a: 1 })).toBe(true)
  })

  it('returns false for null', () => {
    expect(isRecord(null)).toBe(false)
  })

  it('returns false for undefined', () => {
    expect(isRecord(undefined)).toBe(false)
  })

  it('returns false for arrays', () => {
    expect(isRecord([])).toBe(false)
    expect(isRecord([1, 2])).toBe(false)
  })

  it('returns false for primitives', () => {
    expect(isRecord('string')).toBe(false)
    expect(isRecord(42)).toBe(false)
    expect(isRecord(true)).toBe(false)
  })

  it('returns true for Object.create(null)', () => {
    expect(isRecord(Object.create(null))).toBe(true)
  })
})

// ================================================================
// asString
// ================================================================

describe('asString', () => {
  it('returns string value when valid', () => {
    expect(asString('hello')).toBe('hello')
  })

  it('trims whitespace without fallback', () => {
    expect(asString('  hello  ')).toBe('hello')
  })

  it('returns undefined for empty string without fallback', () => {
    expect(asString('')).toBe(undefined)
  })

  it('returns undefined for whitespace-only string without fallback', () => {
    expect(asString('   ')).toBe(undefined)
  })

  it('returns undefined for non-string without fallback', () => {
    expect(asString(42)).toBe(undefined)
    expect(asString(null)).toBe(undefined)
    expect(asString(undefined)).toBe(undefined)
  })

  it('returns fallback for non-string with fallback', () => {
    expect(asString(42, 'default')).toBe('default')
    expect(asString(null, 'default')).toBe('default')
  })

  it('returns original string with fallback (no trim)', () => {
    expect(asString('  hello  ', 'default')).toBe('  hello  ')
  })

  it('returns empty string with fallback', () => {
    expect(asString('', 'default')).toBe('')
  })
})

// ================================================================
// asNumber
// ================================================================

describe('asNumber', () => {
  it('returns number value when finite', () => {
    expect(asNumber(42)).toBe(42)
    expect(asNumber(0)).toBe(0)
    expect(asNumber(-3.14)).toBe(-3.14)
  })

  it('returns undefined for non-number without fallback', () => {
    expect(asNumber('42')).toBe(undefined)
    expect(asNumber(null)).toBe(undefined)
  })

  it('returns undefined for NaN without fallback', () => {
    expect(asNumber(NaN)).toBe(undefined)
  })

  it('returns undefined for Infinity without fallback', () => {
    expect(asNumber(Infinity)).toBe(undefined)
    expect(asNumber(-Infinity)).toBe(undefined)
  })

  it('returns fallback for non-number with fallback', () => {
    expect(asNumber('42', 0)).toBe(0)
    expect(asNumber(NaN, 10)).toBe(10)
    expect(asNumber(Infinity, 5)).toBe(5)
  })

  it('returns number even with fallback', () => {
    expect(asNumber(42, 0)).toBe(42)
  })
})

// ================================================================
// asBoolean
// ================================================================

describe('asBoolean', () => {
  it('returns boolean value when boolean', () => {
    expect(asBoolean(true)).toBe(true)
    expect(asBoolean(false)).toBe(false)
  })

  it('returns undefined for non-boolean without fallback', () => {
    expect(asBoolean(1)).toBe(undefined)
    expect(asBoolean('true')).toBe(undefined)
    expect(asBoolean(null)).toBe(undefined)
  })

  it('returns fallback for non-boolean with fallback', () => {
    expect(asBoolean(1, false)).toBe(false)
    expect(asBoolean('true', true)).toBe(true)
  })

  it('returns boolean even with fallback', () => {
    expect(asBoolean(true, false)).toBe(true)
  })
})

// ================================================================
// asInt
// ================================================================

describe('asInt', () => {
  it('returns truncated integer for finite number', () => {
    expect(asInt(42)).toBe(42)
    expect(asInt(3.9)).toBe(3)
    expect(asInt(-3.9)).toBe(-3)
  })

  it('returns integer from numeric string', () => {
    expect(asInt('42')).toBe(42)
    expect(asInt('  7  ')).toBe(7)
  })

  it('returns undefined for non-finite number', () => {
    expect(asInt(NaN)).toBe(undefined)
    expect(asInt(Infinity)).toBe(undefined)
  })

  it('returns undefined for non-numeric string', () => {
    expect(asInt('hello')).toBe(undefined)
    expect(asInt('3.14')).toBe(3)
  })

  it('returns undefined for null/undefined/object', () => {
    expect(asInt(null)).toBe(undefined)
    expect(asInt(undefined)).toBe(undefined)
    expect(asInt({})).toBe(undefined)
  })

  it('returns 0 for 0', () => {
    expect(asInt(0)).toBe(0)
  })

  it('returns negative integer', () => {
    expect(asInt(-5)).toBe(-5)
  })
})

// ================================================================
// asStringArray
// ================================================================

describe('asStringArray', () => {
  it('returns string array from valid input', () => {
    expect(asStringArray(['a', 'b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('trims whitespace from strings', () => {
    expect(asStringArray(['  a  ', 'b'])).toEqual(['a', 'b'])
  })

  it('filters out non-string items', () => {
    expect(asStringArray(['a', 42, true, 'b'])).toEqual(['a', 'b'])
  })

  it('filters out empty strings after trim', () => {
    expect(asStringArray(['a', '   ', '', 'b'])).toEqual(['a', 'b'])
  })

  it('returns empty array for non-array', () => {
    expect(asStringArray(null)).toEqual([])
    expect(asStringArray(undefined)).toEqual([])
    expect(asStringArray('string')).toEqual([])
    expect(asStringArray(42)).toEqual([])
  })

  it('returns empty array for empty array', () => {
    expect(asStringArray([])).toEqual([])
  })
})

// ================================================================
// asRecordArray
// ================================================================

describe('asRecordArray', () => {
  it('returns record array from valid input', () => {
    const input = [{ a: 1 }, { b: 2 }]
    expect(asRecordArray(input)).toEqual(input)
  })

  it('filters out non-record items', () => {
    const input = [{ a: 1 }, 'string', 42, null, [1, 2]]
    expect(asRecordArray(input)).toEqual([{ a: 1 }])
  })

  it('returns empty array for non-array', () => {
    expect(asRecordArray(null)).toEqual([])
    expect(asRecordArray(undefined)).toEqual([])
    expect(asRecordArray({})).toEqual([])
  })

  it('returns empty array for empty array', () => {
    expect(asRecordArray([])).toEqual([])
  })
})

// ================================================================
// asNullableString
// ================================================================

describe('asNullableString', () => {
  it('returns string value', () => {
    expect(asNullableString('hello')).toBe('hello')
  })

  it('returns null for non-string', () => {
    expect(asNullableString(42)).toBe(null)
    expect(asNullableString(null)).toBe(null)
    expect(asNullableString(undefined)).toBe(null)
  })

  it('returns null for empty string', () => {
    expect(asNullableString('')).toBe(null)
  })

  it('returns null for whitespace-only', () => {
    expect(asNullableString('   ')).toBe(null)
  })

  it('trims valid strings', () => {
    expect(asNullableString('  hello  ')).toBe('hello')
  })
})

// ================================================================
// asStringList
// ================================================================

describe('asStringList', () => {
  it('returns string array from string items', () => {
    expect(asStringList(['a', 'b'])).toEqual(['a', 'b'])
  })

  it('extracts name from record items', () => {
    expect(asStringList([{ name: 'agent-1' }])).toEqual(['agent-1'])
  })

  it('extracts id from record items when name missing', () => {
    expect(asStringList([{ id: 'id-1' }])).toEqual(['id-1'])
  })

  it('extracts skill from record items when name/id missing', () => {
    expect(asStringList([{ skill: 'review' }])).toEqual(['review'])
  })

  it('mixes strings and records', () => {
    expect(asStringList(['a', { name: 'b' }, 42])).toEqual(['a', 'b'])
  })

  it('trims whitespace', () => {
    expect(asStringList(['  a  ', { name: '  b  ' }])).toEqual(['a', 'b'])
  })

  it('returns empty array for non-array', () => {
    expect(asStringList(null)).toEqual([])
    expect(asStringList(undefined)).toEqual([])
  })

  it('returns empty array for empty array', () => {
    expect(asStringList([])).toEqual([])
  })

  it('skips empty strings and empty records', () => {
    expect(asStringList(['', { name: '' }, { id: '' }, { skill: '' }, 'valid'])).toEqual(['valid'])
  })
})

// ================================================================
// extractArray
// ================================================================

describe('extractArray', () => {
  it('returns array as-is', () => {
    expect(extractArray([1, 2, 3])).toEqual([1, 2, 3])
  })

  it('extracts from record by key', () => {
    expect(extractArray({ items: [1, 2], other: 'x' }, ['items'])).toEqual([1, 2])
  })

  it('tries keys in order', () => {
    expect(extractArray({ a: 'not-array', b: [1, 2] }, ['a', 'b'])).toEqual([1, 2])
  })

  it('returns first matching key', () => {
    expect(extractArray({ a: [1], b: [2, 3] }, ['a', 'b'])).toEqual([1])
  })

  it('returns empty array when no key matches', () => {
    expect(extractArray({ x: 1 }, ['a', 'b'])).toEqual([])
  })

  it('returns empty array for null', () => {
    expect(extractArray(null)).toEqual([])
  })

  it('returns empty array for undefined', () => {
    expect(extractArray(undefined)).toEqual([])
  })

  it('returns empty array for primitives', () => {
    expect(extractArray('string')).toEqual([])
    expect(extractArray(42)).toEqual([])
  })

  it('defaults keys to empty array', () => {
    expect(extractArray({ a: [1] })).toEqual([])
  })
})

// ================================================================
// toIsoTimestamp
// ================================================================

describe('toIsoTimestamp', () => {
  it('returns string as-is when non-empty', () => {
    expect(toIsoTimestamp('2026-04-17T10:00:00Z')).toBe('2026-04-17T10:00:00Z')
  })

  it('returns trimmed-check passes for original value', () => {
    // toIsoTimestamp checks value.trim() !== '' but returns original value
    expect(toIsoTimestamp('  2026-04-17T10:00:00Z  ')).toBe('  2026-04-17T10:00:00Z  ')
  })

  it('returns undefined for empty string', () => {
    expect(toIsoTimestamp('')).toBe(undefined)
  })

  it('returns undefined for whitespace-only string', () => {
    expect(toIsoTimestamp('   ')).toBe(undefined)
  })

  it('converts unix timestamp to ISO string', () => {
    // 2026-04-17 10:00:00 UTC = 1776420000 (approx)
    const result = toIsoTimestamp(1776420000)
    expect(result).toBeTruthy()
    expect(result!.endsWith('Z')).toBe(true)
  })

  it('returns undefined for zero timestamp', () => {
    expect(toIsoTimestamp(0)).toBe(undefined)
  })

  it('returns undefined for negative timestamp', () => {
    expect(toIsoTimestamp(-1)).toBe(undefined)
  })

  it('returns undefined for NaN', () => {
    expect(toIsoTimestamp(NaN)).toBe(undefined)
  })

  it('returns undefined for Infinity', () => {
    expect(toIsoTimestamp(Infinity)).toBe(undefined)
  })

  it('returns undefined for null', () => {
    expect(toIsoTimestamp(null)).toBe(undefined)
  })

  it('returns undefined for undefined', () => {
    expect(toIsoTimestamp(undefined)).toBe(undefined)
  })
})
