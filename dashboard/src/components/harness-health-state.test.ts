import { describe, it, expect } from 'vitest'
import { mergeRecent, decodeEventPayload } from './harness-health-state'

describe('mergeRecent', () => {
  it('prepends new item to empty list', () => {
    const result = mergeRecent([], 'a', (l, r) => l === r, 5)
    expect(result).toEqual(['a'])
  })

  it('prepends new item to existing list', () => {
    const result = mergeRecent(['b', 'c'], 'a', (l, r) => l === r, 5)
    expect(result).toEqual(['a', 'b', 'c'])
  })

  it('removes duplicate when isSame matches', () => {
    const result = mergeRecent(['a', 'b', 'c'], 'b', (l, r) => l === r, 5)
    expect(result).toEqual(['b', 'a', 'c'])
  })

  it('truncates to maxItems', () => {
    const result = mergeRecent(['a', 'b', 'c', 'd'], 'e', (l, r) => l === r, 3)
    expect(result).toEqual(['e', 'a', 'b'])
  })

  it('keeps all items when under maxItems', () => {
    const result = mergeRecent(['a', 'b'], 'c', (l, r) => l === r, 10)
    expect(result).toEqual(['c', 'a', 'b'])
  })

  it('maxItems=1 keeps only the new item', () => {
    const result = mergeRecent(['a', 'b'], 'c', (l, r) => l === r, 1)
    expect(result).toEqual(['c'])
  })

  it('handles duplicate removal with object identity', () => {
    type Item = { id: number; name: string }
    const current: Item[] = [
      { id: 1, name: 'first' },
      { id: 2, name: 'second' },
    ]
    const next: Item = { id: 1, name: 'first-updated' }
    const result = mergeRecent(current, next, (l, r) => l.id === r.id, 5)
    expect(result).toHaveLength(2)
    expect(result[0]).toEqual(next)
    expect(result[1]).toEqual({ id: 2, name: 'second' })
  })

  it('preserves order of non-duplicate items', () => {
    const result = mergeRecent(['x', 'y', 'z'], 'y', (l, r) => l === r, 10)
    expect(result).toEqual(['y', 'x', 'z'])
  })

  it('works with maxItems=0 returning empty', () => {
    const result = mergeRecent(['a', 'b'], 'c', (l, r) => l === r, 0)
    expect(result).toEqual([])
  })

  it('does not remove items when isSame always returns false', () => {
    const result = mergeRecent(['a', 'b'], 'a', () => false, 5)
    expect(result).toEqual(['a', 'a', 'b'])
  })
})

describe('decodeEventPayload', () => {
  it('returns null for null input', () => {
    expect(decodeEventPayload(null)).toBeNull()
  })

  it('returns null for undefined input', () => {
    expect(decodeEventPayload(undefined)).toBeNull()
  })

  it('returns null for string input', () => {
    expect(decodeEventPayload('event')).toBeNull()
  })

  it('returns null for number input', () => {
    expect(decodeEventPayload(42)).toBeNull()
  })

  it('returns null for array input', () => {
    expect(decodeEventPayload([1, 2, 3])).toBeNull()
  })

  it('returns null when object has no payload field', () => {
    expect(decodeEventPayload({ type: 'test' })).toBeNull()
  })

  it('returns null when payload is null', () => {
    expect(decodeEventPayload({ payload: null })).toBeNull()
  })

  it('returns null when payload is a string', () => {
    expect(decodeEventPayload({ payload: 'data' })).toBeNull()
  })

  it('returns payload when it is a record', () => {
    const payload = { task_id: '123', gate: 'approve' }
    expect(decodeEventPayload({ payload })).toEqual(payload)
  })

  it('returns payload when it is an empty object', () => {
    expect(decodeEventPayload({ payload: {} })).toEqual({})
  })

  it('returns payload when it is nested record', () => {
    const payload = { nested: { deep: true } }
    expect(decodeEventPayload({ payload })).toEqual(payload)
  })

  it('returns null when payload is an array (not a plain record)', () => {
    expect(decodeEventPayload({ payload: [1, 2] })).toBeNull()
  })
})
