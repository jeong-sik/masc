import { Schema } from 'effect'
import { isCandleAmount, isCandleAccountRevision, type CandleObservation } from '../../lib/candle-observation'
export * from '../../lib/candle-observation'

export const CandleAmountSchema = Schema.String.pipe(
  Schema.filter(isCandleAmount),
)
export const CandleBalanceSchema = Schema.NullOr(CandleAmountSchema)
export const CandleAccountRevisionSchema = Schema.NullOr(Schema.String.pipe(
  Schema.filter(isCandleAccountRevision),
))
export const CandleObservationSchema: Schema.Schema<CandleObservation> = Schema.Union(
  Schema.Struct({ status: Schema.Literal('off') }),
  Schema.Struct({ status: Schema.Literal('disabled'), reason: Schema.String.pipe(Schema.filter(value => value.trim().length > 0)) }),
  Schema.Struct({
    status: Schema.Literal('ready'),
    issued_milli: CandleAmountSchema,
    burned_milli: CandleAmountSchema,
    circulating_milli: CandleAmountSchema,
  }).pipe(Schema.filter(value => BigInt(value.issued_milli) === BigInt(value.burned_milli) + BigInt(value.circulating_milli))),
)
