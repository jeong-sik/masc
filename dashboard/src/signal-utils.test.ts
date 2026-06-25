import { describe, it, expect } from 'vitest'
import { signal } from '@preact/signals'
import { setIfChanged, setArrayIfChanged, setArrayByKeyIfChanged } from './signal-utils'

describe('setIfChanged', () => {
  it('updates when value differs', () => {
    const s = signal(1)
    setIfChanged(s, 2)
    expect(s.value).toBe(2)
  })

  it('skips when value is the same', () => {
    const obj = { a: 1 }
    const s = signal(obj)
    setIfChanged(s, obj)
    // Verify it's still the exact same reference
    expect(s.value).toBe(obj)
  })

  it('updates when referentially different even if structurally equal', () => {
    const s = signal({ a: 1 })
    const newObj = { a: 1 }
    setIfChanged(s, newObj)
    expect(s.value).toBe(newObj)
  })
})

describe('setArrayIfChanged', () => {
  it('updates when length differs', () => {
    const s = signal([1, 2, 3])
    setArrayIfChanged(s, [1, 2])
    expect(s.value).toEqual([1, 2])
  })

  it('updates when first element differs', () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const c = { id: 'c' }
    const s = signal([a, b])
    setArrayIfChanged(s, [c, b])
    expect(s.value[0]).toBe(c)
  })

  it('updates when last element differs', () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const c = { id: 'c' }
    const s = signal([a, b])
    setArrayIfChanged(s, [a, c])
    expect(s.value[1]).toBe(c)
  })

  it('skips when boundary elements are the same references', () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const arr = [a, b]
    const s = signal(arr)
    // Same length, same first and last references
    setArrayIfChanged(s, [a, b])
    expect(s.value).toBe(arr)
  })

  it('handles empty arrays', () => {
    const empty: number[] = []
    const s = signal(empty)
    setArrayIfChanged(s, [])
    expect(s.value).toBe(empty) // same length (0), no elements to compare
  })
})

describe('setArrayByKeyIfChanged', () => {
  const keyFn = (item: { id: string }) => item.id

  it('updates when length differs', () => {
    const s = signal([{ id: 'a' }, { id: 'b' }])
    setArrayByKeyIfChanged(s, [{ id: 'a' }], keyFn)
    expect(s.value).toHaveLength(1)
  })

  it('updates when first key differs', () => {
    const original = [{ id: 'a' }, { id: 'b' }]
    const s = signal(original)
    const next = [{ id: 'c' }, { id: 'b' }]
    setArrayByKeyIfChanged(s, next, keyFn)
    expect(s.value).not.toBe(original)
    expect(s.value).toEqual(next)
  })

  it('updates when last key differs', () => {
    const original = [{ id: 'a' }, { id: 'b' }]
    const s = signal(original)
    const next = [{ id: 'a' }, { id: 'c' }]
    setArrayByKeyIfChanged(s, next, keyFn)
    expect(s.value).not.toBe(original)
    expect(s.value).toEqual(next)
  })

  it('updates when a middle key differs', () => {
    const original = [{ id: 'a' }, { id: 'b' }, { id: 'c' }]
    const s = signal(original)
    const next = [{ id: 'a' }, { id: 'x' }, { id: 'c' }]
    setArrayByKeyIfChanged(s, next, keyFn)
    expect(s.value).not.toBe(original)
    expect(s.value).toEqual(next)
  })

  it('updates by default when same-key items are fresh references', () => {
    const original = [{ id: 'a' }, { id: 'b' }]
    const s = signal(original)
    const next = [{ id: 'a' }, { id: 'b' }]
    setArrayByKeyIfChanged(s, next, keyFn)
    expect(s.value).not.toBe(original)
    expect(s.value).toEqual(next)
  })

  it('skips when keys and values match with a structural equality predicate', () => {
    const original = [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }]
    const s = signal(original)
    setArrayByKeyIfChanged(
      s,
      [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }],
      item => item.id,
      (previous, next) => previous.title === next.title,
    )
    expect(s.value).toBe(original)
  })

  it('preserves unchanged item references while replacing changed items', () => {
    const first = { id: 'a', title: 'A' }
    const second = { id: 'b', title: 'B' }
    const original = [first, second]
    const changedSecond = { id: 'b', title: 'B2' }
    const s = signal(original)
    setArrayByKeyIfChanged(
      s,
      [{ id: 'a', title: 'A' }, changedSecond],
      item => item.id,
      (previous, next) => previous.title === next.title,
    )
    expect(s.value).not.toBe(original)
    expect(s.value[0]).toBe(first)
    expect(s.value[1]).toBe(changedSecond)
  })

  it('skips empty arrays', () => {
    const empty: { id: string }[] = []
    const s = signal(empty)
    setArrayByKeyIfChanged(s, [], keyFn)
    expect(s.value).toBe(empty)
  })
})
