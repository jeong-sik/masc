import { Schema } from 'effect'
import { isCandleAmount, isCandleAccountRevision, isCandleObservation, type CandleObservation } from '../../lib/candle-observation'
export * from '../../lib/candle-observation'

export const CandleAmountSchema = Schema.String.pipe(
  Schema.filter(isCandleAmount),
)
export const CandleAccountRevisionSchema = Schema.NullOr(Schema.String.pipe(
  Schema.filter(isCandleAccountRevision),
))
export const CandleObservationSchema: Schema.Schema<CandleObservation> = Schema.declare(isCandleObservation)
