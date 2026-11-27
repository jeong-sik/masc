import { describe, expect, it } from 'vitest'
import { parseUniqueJson } from './json-unique'

describe('parseUniqueJson', () => {
  it('parses nested objects, arrays, strings with escapes, and primitives', () => {
    const raw = JSON.stringify({
      a: 1,
      b: 'hello "world" \\n line',
      c: [true, false, null, -3.14e2, { x: 1, y: 2, z: 3, w: 4, v: 5 }],
      d: {},
      e: [],
    })
    expect(parseUniqueJson(raw)).toEqual(JSON.parse(raw))
  })

  it('rejects duplicate object members in small and large objects', () => {
    expect(() => parseUniqueJson('{"a":1,"a":2}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k3":6}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"outer":[{"inner":1,"inner":2}]}')).toThrow(/duplicate JSON member/)
  })

  it('detects duplicate keys across unicode escape sequences', () => {
    expect(() => parseUniqueJson('{"a":1,"\\u0061":2}')).toThrow(/duplicate JSON member/)
  })

  it('allows identical keys in sibling objects inside an array', () => {
    const raw = '[{"id":1,"name":"alpha"},{"id":2,"name":"beta"}]'
    expect(parseUniqueJson(raw)).toEqual([
      { id: 1, name: 'alpha' },
      { id: 2, name: 'beta' },
    ])
  })

  it('handles tricky backslash and quote escape combinations accurately', () => {
    const raw = '{"": "", "\\\\": "\\\\\\"", "\\"\\\\": "a\\\\b", "x\\"y": "ok"}'
    expect(parseUniqueJson(raw)).toEqual(JSON.parse(raw))
    expect(() => parseUniqueJson('{"\\\\":1,"\\\\":2}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a\\"b":1,"a\\"b":2}')).toThrow(/duplicate JSON member/)
  })

  it('handles __proto__, integer-key reordering, container overwrite races, and deep nesting', () => {
    expect(() => parseUniqueJson('{"__proto__":1,"__proto__":2}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"__proto__":{"a":1,"a":2}}')).toThrow(/duplicate JSON member/)
    const validProto = parseUniqueJson('{"__proto__":{"a":1},"b":2}') as Record<string, unknown>
    expect(Object.getOwnPropertyDescriptor(validProto, '__proto__')?.value).toEqual({ a: 1 })
    expect(validProto.b).toBe(2)

    // Container overwritten by primitive or different-shape container
    expect(() => parseUniqueJson('{"a":{"x":1},"a":5}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a":5,"a":{"x":1}}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a":{"x":1},"a":{"y":2}}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a":[1,2],"a":[1]}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a":[1],"a":[1,2]}')).toThrow(/duplicate JSON member/)
    expect(() => parseUniqueJson('{"a":[{"x":1}],"a":[123]}')).toThrow(/duplicate JSON member/)

    // Integer keys reordered by Object.keys vs source order
    expect(parseUniqueJson('{"b":{"x":1},"0":{"y":2}}')).toEqual({ b: { x: 1 }, 0: { y: 2 } })
    expect(() => parseUniqueJson('{"1":1,"0":2,"1":3}')).toThrow(/duplicate JSON member/)

    // Escaped key with nested duplicate
    expect(() => parseUniqueJson('{"a\\nb":{"x":1,"x":2}}')).toThrow(/duplicate JSON member/)

    // Deep nesting (iterative stack: no call stack overflow)
    const depth = 200
    const deep = `${'{"k":'.repeat(depth)}1${'}'.repeat(depth)}`
    expect(parseUniqueJson(deep)).toEqual(JSON.parse(deep))
    const deepDup = `${'{"k":'.repeat(depth)}{"d":1,"d":2}${'}'.repeat(depth)}`
    expect(() => parseUniqueJson(deepDup)).toThrow(/duplicate JSON member/)
  })
})
