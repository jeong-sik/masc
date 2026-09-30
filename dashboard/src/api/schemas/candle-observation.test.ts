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
})
