import { describe, it, expect } from 'vitest'
import { RingBuffer } from './ring-buffer'

describe('RingBuffer', () => {
  it('rejects non-positive capacity', () => {
    expect(() => new RingBuffer(0)).toThrow()
    expect(() => new RingBuffer(-1)).toThrow()
    expect(() => new RingBuffer(1.5)).toThrow()
  })

  it('starts empty', () => {
    const r = new RingBuffer<number>(4)
    expect(r.size).toBe(0)
    expect(r.toArray()).toEqual([])
    expect(r.peek()).toBeUndefined()
  })

  it('push inserts newest-first', () => {
    const r = new RingBuffer<number>(4)
    r.push(1)
    r.push(2)
    r.push(3)
    expect(r.size).toBe(3)
    expect(r.toArray()).toEqual([3, 2, 1])
    expect(r.peek()).toBe(3)
  })

  it('evicts oldest when capacity exceeded', () => {
    const r = new RingBuffer<number>(3)
    r.push(1)
    r.push(2)
    r.push(3)
    r.push(4)
    r.push(5)
    expect(r.size).toBe(3)
    expect(r.toArray()).toEqual([5, 4, 3])
  })

  it('matches legacy [x, ...arr].slice(0, N) output for N pushes', () => {
    const capacity = 5
    const r = new RingBuffer<string>(capacity)
    let legacy: string[] = []
    for (let i = 0; i < 20; i += 1) {
      const item = `e${i}`
      r.push(item)
      legacy = [item, ...legacy].slice(0, capacity)
      expect(r.toArray()).toEqual(legacy)
    }
  })

  it('clear resets state', () => {
    const r = new RingBuffer<number>(3)
    r.push(1)
    r.push(2)
    r.clear()
    expect(r.size).toBe(0)
    expect(r.toArray()).toEqual([])
    expect(r.peek()).toBeUndefined()
    r.push(9)
    expect(r.toArray()).toEqual([9])
  })

  it('capacity=1 keeps only the newest', () => {
    const r = new RingBuffer<number>(1)
    r.push(1)
    r.push(2)
    r.push(3)
    expect(r.toArray()).toEqual([3])
  })

  it('toArray returns a fresh array each call', () => {
    const r = new RingBuffer<number>(2)
    r.push(1)
    const a = r.toArray()
    r.push(2)
    const b = r.toArray()
    expect(a).not.toBe(b)
    expect(a).toEqual([1])
    expect(b).toEqual([2, 1])
  })
})
