import { describe, expect, it } from 'vitest'

import { memoizeLru } from './lru-cache'

describe('memoizeLru', () => {
  it('computes once per distinct key', () => {
    let calls = 0
    const m = memoizeLru((x: string) => { calls += 1; return x.toUpperCase() }, { max: 8 })
    expect(m('a')).toBe('A')
    expect(m('a')).toBe('A')
    expect(m('a')).toBe('A')
    expect(calls).toBe(1) // discriminator: without caching this would be 3
    expect(m('b')).toBe('B')
    expect(calls).toBe(2)
    expect(m.size).toBe(2)
  })

  it('evicts the least-recently-used entry on overflow', () => {
    const computed: string[] = []
    const m = memoizeLru((x: string) => { computed.push(x); return x }, { max: 2 })
    m('a'); m('b')           // cache: [a, b]
    m('a')                   // touch a -> cache: [b, a]
    m('c')                   // overflow -> evict b -> cache: [a, c]
    expect(m.size).toBe(2)
    m('b')                   // b was evicted -> recomputed
    expect(computed).toEqual(['a', 'b', 'c', 'b'])
  })

  it('caches a falsy result without recomputing', () => {
    let calls = 0
    const m = memoizeLru((_x: string): string => { calls += 1; return '' }, { max: 4 })
    expect(m('k')).toBe('')
    expect(m('k')).toBe('')
    expect(calls).toBe(1) // empty-string result must still be a cache hit
  })

  it('uses a custom key function', () => {
    let calls = 0
    const m = memoizeLru((n: { id: number; v: string }) => { calls += 1; return n.v }, {
      max: 4,
      key: (n) => String(n.id),
    })
    expect(m({ id: 1, v: 'first' })).toBe('first')
    expect(m({ id: 1, v: 'second' })).toBe('first') // same id -> cache hit, ignores v
    expect(calls).toBe(1)
  })

  it('clears all entries', () => {
    const m = memoizeLru((x: string) => x, { max: 4 })
    m('a'); m('b')
    expect(m.size).toBe(2)
    m.clear()
    expect(m.size).toBe(0)
  })

  it('rejects a max below 1', () => {
    expect(() => memoizeLru((x: string) => x, { max: 0 })).toThrow()
  })
})
