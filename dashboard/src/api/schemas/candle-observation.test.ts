import { describe, expect, it } from 'vitest'
import { candleAmountText, readCandleBalance, readCandleObservation } from './candle-observation'

const ready = { status: 'ready', issued_milli: '18446744073709551614000', burned_milli: '1000', circulating_milli: '18446744073709551613000' } as const

describe('Candle observation', () => {
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
    for (const value of [undefined, 0, 9007199254740993, '01', '+1', '-1', '1.0', '1e3', '']) {
      expect(readCandleBalance(value)).toBeUndefined()
    }
    expect(readCandleBalance(null)).toBeNull()
    expect(readCandleObservation({ status: 'off' })).toEqual({ status: 'off' })
    expect(readCandleObservation({ status: 'disabled', reason: 'ledger unreadable' })).toEqual({ status: 'disabled', reason: 'ledger unreadable' })
  })
})
