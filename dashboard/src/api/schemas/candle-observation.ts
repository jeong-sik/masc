import { isRecord } from '../../lib/type-guards'

export type CandleObservation =
  | { readonly status: 'off' }
  | { readonly status: 'disabled'; readonly reason: string }
  | { readonly status: 'ready'; readonly issued_milli: string;
      readonly burned_milli: string; readonly circulating_milli: string }
export type CandleReading = CandleObservation | { readonly status: 'unavailable'; readonly reason: string }

/** Canonical nonnegative millicandle wire amount, shared by observations and Item accounts. */
export function isCandleAmount(value: unknown): value is string {
  return typeof value === 'string' && /^(0|[1-9][0-9]*)$/.exec(value)?.[0] === value
}

/** One strict wire predicate; decimal amounts never pass through a Number. */
function isCandleObservation(value: unknown): value is CandleObservation {
  if (!isRecord(value) || !Object.hasOwn(value, 'status')) return false
  switch (value.status) {
    case 'off': return Object.keys(value).length === 1
    case 'disabled':
      return Object.keys(value).length === 2 && Object.hasOwn(value, 'reason')
        && typeof value.reason === 'string' && value.reason.trim().length > 0
    case 'ready':
      return Object.keys(value).length === 4
        && Object.hasOwn(value, 'issued_milli') && isCandleAmount(value.issued_milli)
        && Object.hasOwn(value, 'burned_milli') && isCandleAmount(value.burned_milli)
        && Object.hasOwn(value, 'circulating_milli') && isCandleAmount(value.circulating_milli)
        && BigInt(value.issued_milli) === BigInt(value.burned_milli) + BigInt(value.circulating_milli)
    default: return false
  }
}

export function readCandleObservation(value: unknown): CandleReading {
  if (!isCandleObservation(value)) {
    return Object.freeze({ status: 'unavailable', reason: 'Candle observation missing or malformed' })
  }
  switch (value.status) {
    case 'off': return Object.freeze({ status: 'off' })
    case 'disabled': return Object.freeze({ status: 'disabled', reason: value.reason })
    case 'ready': return Object.freeze({ status: 'ready', issued_milli: value.issued_milli,
      burned_milli: value.burned_milli, circulating_milli: value.circulating_milli })
  }
}

/** Undefined is malformed/missing; null is the server's explicit Off/Disabled balance. */
export function readCandleBalance(value: unknown): string | null | undefined {
  return value === null ? null : isCandleAmount(value) ? value : undefined
}

function candleRosterAgrees(reading: CandleObservation, rows: unknown): boolean {
  if (!Array.isArray(rows)) return false
  for (const row of rows) {
    if (!isRecord(row) || !Object.hasOwn(row, 'candle_balance_milli')) return false
    const balance = readCandleBalance(row.candle_balance_milli)
    if (reading.status === 'ready' ? typeof balance !== 'string' : balance !== null) return false
  }
  return true
}

/** Validate the summary and every raw row from the same server observation.
 * Roster fields belong to the Keeper decoder; only this monetary field is read here. */
export function readCandleRosterObservation(value: unknown, rows: unknown): CandleReading {
  const reading = readCandleObservation(value)
  if (reading.status === 'unavailable') return reading
  if (!candleRosterAgrees(reading, rows)) {
    return Object.freeze({ status: 'unavailable', reason: 'Candle row balances disagree with the envelope observation' })
  }
  return reading
}

/** Decimal placement only; money never passes through a JavaScript number. */
export function candleAmountText(milli: string): string {
  const padded = milli.padStart(4, '0')
  return `${padded.slice(0, -3)}.${padded.slice(-3)}`
}
