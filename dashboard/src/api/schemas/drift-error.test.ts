import { describe, expect, it } from 'vitest'
import { number, object, string, type BaseIssue } from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

class TestDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('test', issues)
  }
}

const PersonSchema = object({ name: string(), age: number() })

describe('SchemaDriftError base', () => {
  it('sets name from the subclass constructor', () => {
    expect(() => parseOrThrow(TestDriftError, PersonSchema, {})).toThrow(TestDriftError)
    try {
      parseOrThrow(TestDriftError, PersonSchema, {})
    } catch (err) {
      expect(err).toBeInstanceOf(TestDriftError)
      expect(err).toBeInstanceOf(SchemaDriftError)
      expect((err as Error).name).toBe('TestDriftError')
    }
  })

  it('carries domain on the error for programmatic branching', () => {
    try {
      parseOrThrow(TestDriftError, PersonSchema, { name: 1, age: 'x' })
    } catch (err) {
      expect((err as SchemaDriftError).domain).toBe('test')
    }
  })

  it('formats the message with pathful issue summary', () => {
    try {
      parseOrThrow(TestDriftError, PersonSchema, { name: 'ok' })
    } catch (err) {
      expect((err as Error).message).toMatch(/^test schema drift:/)
      expect((err as Error).message).toContain('age')
    }
  })

  it('abortEarly default keeps issues array bounded to a single entry', () => {
    // Memory bound per /simplify review: drifted payloads do not pin
    // hundreds of issue objects on the thrown error.
    try {
      parseOrThrow(TestDriftError, PersonSchema, { name: 1, age: 'x' })
    } catch (err) {
      expect((err as SchemaDriftError).issues).toHaveLength(1)
    }
  })

  it('returns the parsed value on success', () => {
    const out = parseOrThrow(TestDriftError, PersonSchema, { name: 'Vincent', age: 36 })
    expect(out).toEqual({ name: 'Vincent', age: 36 })
  })
})
