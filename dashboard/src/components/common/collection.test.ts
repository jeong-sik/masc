import { describe, it, expect } from 'vitest'
import { groupByKey } from './collection'

describe('groupByKey', () => {
  it('groups items by key function', () => {
    const items = [
      { cat: 'a', val: 1 },
      { cat: 'b', val: 2 },
      { cat: 'a', val: 3 },
    ]
    const result = groupByKey(items, i => i.cat)
    expect(result.get('a')).toEqual([{ cat: 'a', val: 1 }, { cat: 'a', val: 3 }])
    expect(result.get('b')).toEqual([{ cat: 'b', val: 2 }])
  })

  it('returns empty Map for empty input', () => {
    const result = groupByKey([], () => 'key')
    expect(result.size).toBe(0)
  })

  it('skips items with null key', () => {
    const items = [{ k: 'a' }, { k: null }, { k: 'a' }]
    const result = groupByKey(items, i => i.k)
    expect(result.size).toBe(1)
    expect(result.get('a')).toHaveLength(2)
  })

  it('skips items with undefined key', () => {
    const items = [{ k: 'a' }, { k: undefined }]
    const result = groupByKey(items, i => i.k)
    expect(result.size).toBe(1)
    expect(result.get('a')).toHaveLength(1)
  })

  it('skips items with empty string key', () => {
    const items = [{ k: 'a' }, { k: '' }]
    const result = groupByKey(items, i => i.k)
    expect(result.size).toBe(1)
  })

  it('handles all items with same key', () => {
    const items = [{ v: 1 }, { v: 2 }, { v: 3 }]
    const result = groupByKey(items, () => 'same')
    expect(result.size).toBe(1)
    expect(result.get('same')).toHaveLength(3)
  })

  it('handles all items with null keys', () => {
    const items = [{ v: 1 }, { v: 2 }]
    const result = groupByKey(items, () => null)
    expect(result.size).toBe(0)
  })
})
