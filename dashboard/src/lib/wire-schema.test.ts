import { describe, expect, it } from 'vitest'
import { Schema, WireParseError } from './wire-schema'

const itemSchema = Schema.Struct({
  claim: Schema.String,
})

const envelopeSchema = Schema.Struct({
  revision: Schema.Int.pipe(Schema.greaterThan(0)),
  facts: Schema.Array(itemSchema),
})

describe('wire-schema onExcessProperty', () => {
  const payload = {
    revision: 2,
    facts: [{ claim: 'Chapter finished', origin: { trace_id: 'source-turn' } }],
    change: { removed: ['old'] },
  }

  it('preserves excess properties across nested structs when onExcessProperty is preserve', () => {
    const decoded = Schema.decodeUnknownSync(envelopeSchema, {
      onExcessProperty: 'preserve',
    })(payload) as Record<string, unknown>

    expect(decoded.revision).toBe(2)
    expect(decoded.change).toEqual({ removed: ['old'] })
    expect((decoded.facts as Array<Record<string, unknown>>)[0]).toEqual({
      claim: 'Chapter finished',
      origin: { trace_id: 'source-turn' },
    })
  })

  it('still rejects invalid declared fields when onExcessProperty is preserve', () => {
    expect(() =>
      Schema.decodeUnknownSync(envelopeSchema, { onExcessProperty: 'preserve' })({
        revision: 0,
        facts: [{ claim: 'ok', origin: { trace_id: 't1' } }],
        extra: true,
      }),
    ).toThrow(WireParseError)
  })

  it('strips excess properties by default (ignore)', () => {
    const decoded = Schema.decodeUnknownSync(envelopeSchema)(payload) as Record<string, unknown>

    expect(decoded).toEqual({
      revision: 2,
      facts: [{ claim: 'Chapter finished' }],
    })
  })

  it('rejects excess properties when onExcessProperty is error', () => {
    expect(() =>
      Schema.decodeUnknownSync(envelopeSchema, { onExcessProperty: 'error' })(payload),
    ).toThrow(WireParseError)
  })

  it('preserves own __proto__ key without mutating the object prototype', () => {
    const raw = JSON.parse('{"claim":"safe","__proto__":{"polluted":true}}') as unknown
    const decoded = Schema.decodeUnknownSync(itemSchema, {
      onExcessProperty: 'preserve',
    })(raw) as Record<string, unknown>

    expect(Object.getPrototypeOf(decoded)).toBe(Object.prototype)
    expect(Object.prototype.hasOwnProperty.call(decoded, '__proto__')).toBe(true)
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
  })
})
