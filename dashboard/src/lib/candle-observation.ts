/** Synchronous wire observations used during initial store normalization.
 * Keep these readers independent of feature schema runtimes. */
export type CandleObservation =
  | { readonly status: 'off' }
  | { readonly status: 'disabled'; readonly reason: string }
  | { readonly status: 'ready'; readonly issued_milli: string; readonly burned_milli: string; readonly circulating_milli: string }
export type CandleReading = CandleObservation | { readonly status: 'unavailable'; readonly reason: string }

export function isCandleAmount(value: unknown): value is string {
  return typeof value === 'string' && /^(0|[1-9][0-9]*)$/.exec(value)?.[0] === value
}

export function isCandleAccountRevision(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && /^[0-9a-f]{64}$/.test(value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hasFields(value: Record<string, unknown>, fields: readonly string[]): boolean {
  const keys = Object.keys(value)
  return keys.length === fields.length && fields.every(field => Object.hasOwn(value, field))
}

export function readCandleObservation(value: unknown): CandleReading {
  if (isRecord(value)) {
    if (value.status === 'off' && hasFields(value, ['status'])) return { status: 'off' }
    if (value.status === 'disabled' && hasFields(value, ['status', 'reason'])
      && typeof value.reason === 'string' && value.reason.trim().length > 0) {
      return { status: 'disabled', reason: value.reason }
    }
    if (value.status === 'ready' && hasFields(value, ['status', 'issued_milli', 'burned_milli', 'circulating_milli'])
      && isCandleAmount(value.issued_milli) && isCandleAmount(value.burned_milli)
      && isCandleAmount(value.circulating_milli)
      && BigInt(value.issued_milli) === BigInt(value.burned_milli) + BigInt(value.circulating_milli)) {
      return { status: 'ready', issued_milli: value.issued_milli,
        burned_milli: value.burned_milli, circulating_milli: value.circulating_milli }
    }
  }
  return { status: 'unavailable', reason: 'Candle observation missing or malformed' }
}

/** Undefined is malformed/missing; null is the server's explicit absent balance. */
export function readCandleBalance(value: unknown): string | null | undefined {
  return value === null ? null : isCandleAmount(value) ? value : undefined
}

export function readCandleAccountRevision(value: unknown): string | null | undefined {
  return value === null ? null : isCandleAccountRevision(value) ? value : undefined
}

/** Validate the summary and every balance from the same server observation. */
export function readCandleRosterObservation(value: unknown, rows: unknown): CandleReading {
  const reading = readCandleObservation(value)
  if (reading.status === 'unavailable') return reading
  if (!Array.isArray(rows) || !rows.every(row => {
    if (!isRecord(row)) return false
    const balance = readCandleBalance(row.candle_balance_milli)
    return reading.status === 'ready' ? typeof balance === 'string' : balance === null
  })) {
    return { status: 'unavailable', reason: 'Candle row balances disagree with the envelope observation' }
  }
  return reading
}

/** Decimal placement only; money never passes through a JavaScript number. */
export function candleAmountText(milli: string): string {
  const padded = milli.padStart(4, '0')
  return `${padded.slice(0, -3)}.${padded.slice(-3)}`
}
