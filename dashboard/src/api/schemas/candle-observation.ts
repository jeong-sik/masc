import { Either, Schema } from 'effect'

export const CandleAmountSchema = Schema.String.pipe(
  Schema.filter(value => /^(0|[1-9][0-9]*)$/.test(value)),
)
export const CandleBalanceSchema = Schema.NullOr(CandleAmountSchema)
export const CandleObservationSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('off') }),
  Schema.Struct({ status: Schema.Literal('disabled'), reason: Schema.String.pipe(Schema.filter(value => value.trim().length > 0)) }),
  Schema.Struct({
    status: Schema.Literal('ready'),
    issued_milli: CandleAmountSchema,
    burned_milli: CandleAmountSchema,
    circulating_milli: CandleAmountSchema,
  }).pipe(Schema.filter(value => BigInt(value.issued_milli) === BigInt(value.burned_milli) + BigInt(value.circulating_milli))),
)
export type CandleObservation = Schema.Schema.Type<typeof CandleObservationSchema>
export type CandleReading = CandleObservation | { readonly status: 'unavailable'; readonly reason: string }

export function readCandleObservation(value: unknown): CandleReading {
  const parsed = Schema.decodeUnknownEither(CandleObservationSchema, { onExcessProperty: 'error' })(value)
  return Either.isRight(parsed) ? parsed.right : { status: 'unavailable', reason: 'Candle observation missing or malformed' }
}

/** Undefined is malformed/missing; null is the server's explicit Off/Disabled balance. */
export function readCandleBalance(value: unknown): string | null | undefined {
  const parsed = Schema.decodeUnknownEither(CandleBalanceSchema)(value)
  return Either.isRight(parsed) ? parsed.right : undefined
}

function candleBalanceAgrees(reading: CandleObservation, balance: string | null | undefined): boolean {
  return reading.status === 'ready' ? typeof balance === 'string' : balance === null
}

const CandleRosterRowsSchema = Schema.Array(Schema.Struct({ candle_balance_milli: CandleBalanceSchema }))

/** Validate the summary and every row from the same server observation. */
export function readCandleRosterObservation(value: unknown, rows: unknown): CandleReading {
  const reading = readCandleObservation(value)
  if (reading.status === 'unavailable') return reading
  const parsed = Schema.decodeUnknownEither(CandleRosterRowsSchema)(rows)
  if (Either.isLeft(parsed) || !parsed.right.every(row => candleBalanceAgrees(reading, row.candle_balance_milli))) {
    return { status: 'unavailable', reason: 'Candle row balances disagree with the envelope observation' }
  }
  return reading
}

/** Decimal placement only; money never passes through a JavaScript number. */
export function candleAmountText(milli: string): string {
  const padded = milli.padStart(4, '0')
  return `${padded.slice(0, -3)}.${padded.slice(-3)}`
}
