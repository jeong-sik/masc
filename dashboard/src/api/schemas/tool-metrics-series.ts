// Tool metrics series schema — schema-at-boundary for
// `GET /api/v1/tool-metrics/series?since_hours=<N>&bucket=hour|day&utc_offset_min=<M>[&tool=<name>]`.
//
// `p50_ms`, `p95_ms` and `max_ms` are null for a bucket in which no call ran:
// there is no call to take them from, and a chart must leave a gap there
// rather than draw zero. Fields the server adds later are dropped on decode.

import { Schema } from 'effect'

const SeriesStatFields = {
  call_count: Schema.Finite,
  failure_count: Schema.Finite,
  deferred_count: Schema.Finite,
  total_ms: Schema.Finite,
  p50_ms: Schema.NullOr(Schema.Finite),
  p95_ms: Schema.NullOr(Schema.Finite),
  max_ms: Schema.NullOr(Schema.Finite),
}

const ToolMetricsSeriesBucketSchema = Schema.Struct({
  start: Schema.Finite,
  ...SeriesStatFields,
})

const ToolMetricsSeriesToolSchema = Schema.Struct({
  name: Schema.String,
  public_names: Schema.Array(Schema.String),
  ...SeriesStatFields,
})

const ToolMetricsSeriesResponseSchema = Schema.Struct({
  generated_at: Schema.Finite,
  window: Schema.Struct({
    since: Schema.Finite,
    until: Schema.Finite,
    bucket: Schema.Literal('hour', 'day'),
    bucket_seconds: Schema.Finite,
    utc_offset_min: Schema.Finite,
  }),
  tool: Schema.NullOr(Schema.String),
  total: Schema.Struct(SeriesStatFields),
  buckets: Schema.Array(ToolMetricsSeriesBucketSchema),
  top_by_time: Schema.Array(ToolMetricsSeriesToolSchema),
})

export type ToolMetricsSeriesBucket = Schema.Schema.Type<typeof ToolMetricsSeriesBucketSchema>
export type ToolMetricsSeriesTool = Schema.Schema.Type<typeof ToolMetricsSeriesToolSchema>
export type ToolMetricsSeriesResponse = Schema.Schema.Type<typeof ToolMetricsSeriesResponseSchema>

/** Throws a `ParseError` that names the field that drifted. */
export const parseToolMetricsSeriesResponse = Schema.decodeUnknownSync(ToolMetricsSeriesResponseSchema)
