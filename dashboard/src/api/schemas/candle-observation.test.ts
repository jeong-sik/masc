import { describe, expect, it } from 'vitest'
import { Either, Schema } from 'effect'
import { CandleObservationSchema, candleAmountText, readCandleAccountRevision, readCandleBalance, readCandleObservation, readCandleRosterObservation } from './candle-observation'

const ready = { status: 'ready', issued_milli: '18446744073709551614000', burned_milli: '1000', circulating_milli: '18446744073709551613000' } as const

describe('Candle observation', () => {
  it('keeps the initial-store reader consistent with the feature schema', () => {
    const inputs: unknown[] = [undefined, null, false, [], {}, ready,
      { status: 'off' }, { status: 'off', extra: true },
      { status: 'disabled', reason: 'ledger unreadable' },
      { status: 'disabled', reason: ' ' }, { status: 'disabled', reason: 1 },
      { ...ready, extra: true }, { ...ready, burned_milli: '0' },
      { status: 'ready', issued_milli: '0', burned_milli: '0', circulating_milli: '0' }]
    for (const field of ['issued_milli', 'burned_milli', 'circulating_milli']) {
      for (const bad of [undefined, null, 1, '01', '-1', '+1', '1.0', '1e3', '', '1\n', '1\r\n', '1\r', '1\u2028', {}, []]) {
        inputs.push({ ...ready, [field]: bad })
      }
      const missing = { ...ready } as Record<string, unknown>
      delete missing[field]
      inputs.push(missing)
    }
    for (const value of inputs) {
      const schema = Schema.decodeUnknownEither(CandleObservationSchema, { onExcessProperty: 'error' })(value)
      const reading = readCandleObservation(value)
      if (Either.isRight(schema)) expect(reading).toEqual(schema.right)
      else expect(reading.status).toBe('unavailable')
    }
  })
  it('rejects inconsistent or malformed row balances without changing the summary contract', () => {
    expect(readCandleRosterObservation(ready, [{ candle_balance_milli: '9007199254740993', name: 'keeper' }])).toEqual(ready)
    expect(readCandleRosterObservation({ status: 'off' }, [{ candle_balance_milli: null }])).toEqual({ status: 'off' })
    for (const rows of [undefined, {}, [null], [{}], [{ candle_balance_milli: 1 }], [{ candle_balance_milli: null }]]) {
      expect(readCandleRosterObservation(ready, rows).status).toBe('unavailable')
    }
    expect(readCandleRosterObservation({ status: 'off' }, [{ candle_balance_milli: '0' }]).status).toBe('unavailable')
  })
  it('keeps aggregate and wallet amounts exact beyond machine integers', () => {
    expect(readCandleObservation(ready)).toEqual(ready)
    expect(readCandleBalance('9007199254740993')).toBe('9007199254740993')
    expect(candleAmountText(ready.issued_milli)).toBe('18446744073709551614.000')
    expect(candleAmountText('1')).toBe('0.001')
    expect(candleAmountText('0')).toBe('0.000')
  })
  it('rejects missing, malformed, rounded and nonconserving observations', () => {
    for (const value of [undefined, null, { status: 'off', issued_milli: '0' }, { status: 'disabled', reason: '' },
      { ...ready, issued_milli: 18446744073709551614000 }, { ...ready, issued_milli: '01' },
      { ...ready, issued_milli: '-1' }, { ...ready, issued_milli: '1e3' }, { ...ready, burned_milli: '0' }]) {
      expect(readCandleObservation(value).status).toBe('unavailable')
    }
    for (const value of [undefined, 0, 9007199254740993, '01', '+1', '-1', '1.0', '1e3', '', '1\n', '1\r\n', '1\r', '1\u2028']) {
      expect(readCandleBalance(value)).toBeUndefined()
    }
    expect(readCandleBalance(null)).toBeNull()
    expect(readCandleAccountRevision('a'.repeat(64))).toBe('a'.repeat(64))
    expect(readCandleAccountRevision(null)).toBeNull()
    for (const value of [undefined, 'A'.repeat(64), 'a'.repeat(63), 'a'.repeat(64) + '\n', 'a'.repeat(64) + '\r\n', 1]) {
      expect(readCandleAccountRevision(value)).toBeUndefined()
    }
    expect(readCandleObservation({ status: 'off' })).toEqual({ status: 'off' })
    expect(readCandleObservation({ status: 'disabled', reason: 'ledger unreadable' })).toEqual({ status: 'disabled', reason: 'ledger unreadable' })
  })

  it('retains exact canonical account revisions and distinguishes missing from null', () => {
    const revision = 'a1'.repeat(32)
    expect(readCandleAccountRevision(revision)).toBe(revision)
    expect(readCandleAccountRevision(null)).toBeNull()
    for (const value of [undefined, 0, {}, '', revision.slice(1), revision + '0',
      revision.toUpperCase(), 'g'.repeat(64), ' ' + revision, revision + ' ',
      revision + '\n', revision + '\r', revision + '\r\n', revision + '\u2028', revision + '\u2029']) {
      expect(readCandleAccountRevision(value)).toBeUndefined()
    }
  })

  it('rejects excess envelope fields and noncanonical amount bytes in every observation', () => {
    for (const value of [{ status: 'off', extra: true }, { status: 'disabled', reason: 'unreadable', extra: true },
      { ...ready, extra: true }, { status: 'disabled', reason: ' \n ' },
      { status: 'ready', issued_milli: '0', burned_milli: '0' }]) {
      expect(readCandleObservation(value).status).toBe('unavailable')
    }
    for (const amount of ['0\n', '1\n', '1\r', '1\r\n', '1\u2028', '1\u2029', ' 1', '1 ', '１', '٠']) {
      expect(readCandleBalance(amount)).toBeUndefined()
      expect(readCandleObservation({ status: 'ready', issued_milli: amount,
        burned_milli: '0', circulating_milli: amount }).status).toBe('unavailable')
    }
  })

  it('keeps the envelope and all raw wallet rows in the same observation', () => {
    expect(readCandleRosterObservation(ready, [
      { name: 'alpha', candle_balance_milli: '9007199254740993', portrait: { state: 'unavailable' } },
      { name: 'beta', candle_balance_milli: '0', status: 'active' },
    ])).toEqual(ready)
    for (const envelope of [{ status: 'off' }, { status: 'disabled', reason: 'ledger unreadable' }]) {
      expect(readCandleRosterObservation(envelope, [{ name: 'alpha', candle_balance_milli: null }])).toEqual(envelope)
      expect(readCandleRosterObservation(envelope, Array(1)).status).toBe('unavailable')
      for (const row of [{ name: 'alpha' }, { candle_balance_milli: undefined }, { candle_balance_milli: '0' }]) {
        expect(readCandleRosterObservation(envelope, [row]).status).toBe('unavailable')
      }
    }
    for (const rows of [undefined, null, {}, Array(1), [null], [{}], [{ candle_balance_milli: null }],
      [{ candle_balance_milli: '1' }, { candle_balance_milli: '01' }]]) {
      expect(readCandleRosterObservation(ready, rows).status).toBe('unavailable')
    }
    expect(readCandleRosterObservation(ready, []).status).toBe('ready')
  })

  it('retains an immutable observation when the original wire record changes', () => {
    const wire = { ...ready }
    const reading = readCandleObservation(wire)
    Object.assign(wire, { issued_milli: '0' })
    expect(reading).toEqual(ready)
    expect(Object.isFrozen(reading)).toBe(true)
  })

})

// Currency availability is checked independently of Gate lifecycle rows.
describe('Candle roster observation', () => {
  it('preserves every valid summary with matching wallet observations', () => {
    for (const candle of [{ status: 'off' }, { status: 'disabled', reason: 'ledger unreadable' }, ready]) {
      expect(readCandleRosterObservation(candle, [{ candle_balance_milli: candle.status === 'ready' ? '0' : null }])).toEqual(candle)
    }
  })
  it('withdraws malformed or inconsistent money while Gate retains lifecycle controls', () => {
    for (const candle of [{ status: 'unknown' }, { status: 'off', reason: 'extra' },
      { status: 'ready', issued_milli: '01', burned_milli: '0', circulating_milli: '1' },
      { status: 'ready', issued_milli: '3', burned_milli: '1', circulating_milli: '1' }]) {
      expect(readCandleRosterObservation(candle, []).status).toBe('unavailable')
    }
    expect(readCandleRosterObservation({ status: 'off' }, [{ candle_balance_milli: '0' }]).status).toBe('unavailable')
    expect(readCandleRosterObservation(ready, [{}]).status).toBe('unavailable')
  })
})
