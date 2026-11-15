// Tool metrics series schema — schema-at-boundary for
// `GET /api/v1/tool-metrics/series?since_hours=<N>&bucket=hour|day&utc_offset_min=<M>[&tool=<name>]`.
//
// `p50_ms`, `p95_ms` and `max_ms` are null for a bucket in which no call ran:
// there is no call to take them from, and a chart must leave a gap there
// rather than draw zero. `long_count` and `long_total_ms` are zero there:
// no call ran past the line, and no time went into one. The line itself is
// the response's `long_call_ms`.
//
// `result_bytes_total` adds up the result sizes of the `result_observed_count`
// calls that have one. A call stored before sizes were kept has none, so the
// total covers fewer calls than `call_count` until the old rows age out.
// `result_bytes_max` is null when no call in the set has a size: a set of calls
// without sizes is not a set of calls that returned nothing.
//
// `failure_classes` counts the failed calls by the class they recorded, and
// `failure_unclassified_count` the failed calls that recorded none (every
// failure stored before classes were kept). The six numbers add up to
// `failure_count`.
// Fields the server adds later are dropped on decode.

import { Schema } from 'effect'

/** The classes of `Tool_result.tool_failure_class`, spelled as the server spells them. */
const FailureClassCountsSchema = Schema.Struct({
  dependency_unavailable: Schema.Finite,
  policy_rejection: Schema.Finite,
  runtime_failure: Schema.Finite,
  workflow_rejection: Schema.Finite,
  operator_cancelled: Schema.Finite,
})

const SeriesStatFields = {
  call_count: Schema.Finite,
  failure_count: Schema.Finite,
  failure_classes: FailureClassCountsSchema,
  failure_unclassified_count: Schema.Finite,
  deferred_count: Schema.Finite,
  total_ms: Schema.Finite,
  p50_ms: Schema.NullOr(Schema.Finite),
  p95_ms: Schema.NullOr(Schema.Finite),
  max_ms: Schema.NullOr(Schema.Finite),
  long_count: Schema.Finite,
  long_total_ms: Schema.Finite,
  result_observed_count: Schema.Finite,
  result_bytes_total: Schema.Finite,
  result_bytes_max: Schema.NullOr(Schema.Finite),
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
  /** A call that ran at least this many milliseconds counts as long. */
  long_call_ms: Schema.Finite,
  total: Schema.Struct(SeriesStatFields),
  buckets: Schema.Array(ToolMetricsSeriesBucketSchema),
  top_by_time: Schema.Array(ToolMetricsSeriesToolSchema),
})

export type ToolMetricsFailureClassCounts = Schema.Schema.Type<typeof FailureClassCountsSchema>
export type ToolMetricsSeriesBucket = Schema.Schema.Type<typeof ToolMetricsSeriesBucketSchema>
export type ToolMetricsSeriesResponse = Schema.Schema.Type<typeof ToolMetricsSeriesResponseSchema>

/** Throws a `ParseError` that names the field that drifted. */
export const parseToolMetricsSeriesResponse = Schema.decodeUnknownSync(ToolMetricsSeriesResponseSchema)

/** One window of the hourly or daily tool-call series. */
export interface ToolMetricsSeriesRequest {
  readonly sinceHours: number
  readonly bucket: 'hour' | 'day'
  /** Minutes east of UTC, so a day bucket starts at the viewer's midnight. */
  readonly utcOffsetMin: number
  /** A stored tool name, or null for every tool. */
  readonly tool: string | null
}

/** The query string the series endpoint reads. */
export function toolMetricsSeriesQuery(request: ToolMetricsSeriesRequest): string {
  const query = new URLSearchParams({
    since_hours: String(request.sinceHours),
    bucket: request.bucket,
    utc_offset_min: String(request.utcOffsetMin),
  })
  if (request.tool !== null) query.set('tool', request.tool)
  return query.toString()
}

const SECONDS_PER_HOUR = 3_600
/** The server finds `since` as `until - since_hours * 3600` in floating point. */
const WINDOW_LENGTH_TOLERANCE_S = 1

/**
 * How the response differs from the request, or null when it answers it.
 * The server ignores a parameter it does not know and fills in a default, so a
 * misspelled name would draw 24 hours of calls under a "7 days" label.
 */
export function seriesAnswerMismatch(
  request: ToolMetricsSeriesRequest,
  response: ToolMetricsSeriesResponse,
): string | null {
  const { window } = response
  const answeredHours = (window.until - window.since) / SECONDS_PER_HOUR
  const differences: string[] = []
  if (Math.abs(window.until - window.since - request.sinceHours * SECONDS_PER_HOUR) > WINDOW_LENGTH_TOLERANCE_S) {
    differences.push(`길이 ${request.sinceHours}시간을 요청했는데 ${answeredHours}시간`)
  }
  if (window.bucket !== request.bucket) {
    differences.push(`구간 ${request.bucket}을 요청했는데 ${window.bucket}`)
  }
  if (window.utc_offset_min !== request.utcOffsetMin) {
    differences.push(`UTC 오프셋 ${request.utcOffsetMin}분을 요청했는데 ${window.utc_offset_min}분`)
  }
  if (response.tool !== request.tool) {
    differences.push(`도구 ${request.tool ?? '전체'}를 요청했는데 ${response.tool ?? '전체'}`)
  }
  return differences.length === 0 ? null : `요청과 다른 구간의 응답입니다: ${differences.join(', ')}`
}
