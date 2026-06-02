// Pure TS unit tests for IdGenerator. No DOM, no Preact runtime.
import { describe, it, expect } from 'vitest'
import { createIdGenerator } from './id-generator'

describe('createIdGenerator', () => {
  it('produces a monotonic sequence starting at 1', () => {
    const gen = createIdGenerator()
    expect(gen.next()).toBe('id-1')
    expect(gen.next()).toBe('id-2')
    expect(gen.next()).toBe('id-3')
  })

  it('uses the supplied seed as the default prefix', () => {
    const gen = createIdGenerator('drawer')
    expect(gen.next()).toBe('drawer-1')
    expect(gen.next()).toBe('drawer-2')
  })

  it('per-call prefix overrides the seed for that call only', () => {
    const gen = createIdGenerator('drawer')
    expect(gen.next('trigger')).toBe('trigger-1')
    expect(gen.next('content')).toBe('content-2')
    // back to default seed on the next call
    expect(gen.next()).toBe('drawer-3')
  })

  it('reset() returns the counter to 0 so the next id starts at 1', () => {
    const gen = createIdGenerator()
    gen.next()
    gen.next()
    gen.next()
    gen.reset()
    expect(gen.next()).toBe('id-1')
  })

  it('two instances are independent: their counters do not share state', () => {
    const a = createIdGenerator('a')
    const b = createIdGenerator('b')
    expect(a.next()).toBe('a-1')
    expect(b.next()).toBe('b-1')
    expect(a.next()).toBe('a-2')
    expect(b.next()).toBe('b-2')
  })

  it('two instances with the same seed produce identical sequences (SSR determinism)', () => {
    const a = createIdGenerator('drawer')
    const b = createIdGenerator('drawer')
    expect(a.next()).toBe(b.next())
    expect(a.next('trigger')).toBe(b.next('trigger'))
    expect(a.next()).toBe(b.next())
  })

  it('undefined seed falls back to the default "id" prefix', () => {
    const gen = createIdGenerator(undefined)
    expect(gen.next()).toBe('id-1')
  })

  it('empty string seed falls back to the default prefix (CSS-escape sharp edge)', () => {
    const gen = createIdGenerator('')
    expect(gen.next()).toBe('id-1')
    // per-call prefix override still works after empty-string seed
    expect(gen.next('explicit')).toBe('explicit-2')
  })
})
