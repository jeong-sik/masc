import { decodeRuntimeModelMetricsResponse, type DashboardRuntimeModelMetricsResponse } from './dashboard-runtime'
import { QueryStreamProtocolError, readQueryObservationStream } from './query-observation-stream'
import { createQueryObservationStream, type QueryStreamReader } from '../lib/query-observation-stream'
import { isRecord } from '../lib/type-guards'

export interface ModelMetricsQuery {
  readonly windowMinutes: number
  readonly bucketMinutes: number
}

export function modelMetricsStreamPath(query: ModelMetricsQuery): string {
  return `/api/v1/models/metrics/stream?window=${query.windowMinutes}&bucket_min=${query.bucketMinutes}`
}

export class ModelMetricsReadError extends Error {
  readonly name = 'ModelMetricsReadError'
}

export function decodeModelMetricsFrame(query: ModelMetricsQuery, wire: unknown): DashboardRuntimeModelMetricsResponse {
  if (isRecord(wire) && typeof wire.error === 'string') throw new ModelMetricsReadError(wire.error)
  const frame = decodeRuntimeModelMetricsResponse(wire)
  if (frame === null || frame.window_minutes !== query.windowMinutes || frame.bucket_minutes !== query.bucketMinutes
    || frame.cost_ledger_read === null || frame.cost_ledger_read?.state === 'pending') {
    throw new QueryStreamProtocolError('Model metrics stream did not answer its original query')
  }
  return frame
}

const subscribe = createQueryObservationStream<ModelMetricsQuery, DashboardRuntimeModelMetricsResponse, ModelMetricsReadError>({
  key: modelMetricsStreamPath,
  recoveryTopics: ['model_metrics'],
  read: (query, _previous, signal, onFrame, onActivity) => readQueryObservationStream(
    modelMetricsStreamPath(query), signal, wire => decodeModelMetricsFrame(query, wire), onFrame, onActivity),
  merge: (_previous, frame) => frame,
  failure: cause => cause instanceof ModelMetricsReadError ? cause
    : new ModelMetricsReadError(cause instanceof Error ? cause.message : String(cause)),
  terminal: cause => cause instanceof QueryStreamProtocolError,
})

export function subscribeModelMetricsStream(
  query: ModelMetricsQuery,
  reader: QueryStreamReader<DashboardRuntimeModelMetricsResponse, ModelMetricsReadError>,
) {
  return subscribe(Object.freeze({ ...query }), reader)
}
