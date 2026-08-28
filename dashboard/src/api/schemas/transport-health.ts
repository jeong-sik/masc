import { Data, Effect, ParseResult, Schema } from 'effect'

const NonNegativeNumberSchema = Schema.JsonNumber.pipe(Schema.nonNegative())
const NonNegativeIntegerSchema = Schema.NonNegativeInt
const PortSchema = Schema.Int.pipe(Schema.between(1, 65_535))

const HotSessionSchema = Schema.Struct({
  session_id: Schema.NonEmptyString,
  kind: Schema.Literal('observer', 'agent_stream', 'presence'),
  queue_depth: NonNegativeIntegerSchema,
  last_event_id: NonNegativeIntegerSchema,
  idle_seconds: NonNegativeNumberSchema,
})

export type HotSession = Schema.Schema.Type<typeof HotSessionSchema>

const SummarySchema = Schema.Struct({
  primary_path: Schema.Literal(
    'grpc_subscribe',
    'websocket',
    'sse',
    'streamable_http',
  ),
  queue_pressure: Schema.Literal('steady', 'watch', 'high'),
  external_fanout_targets: NonNegativeIntegerSchema,
})

const SseOuterSchema = Schema.Struct({
  sessions_observer: NonNegativeIntegerSchema,
  sessions_agent_stream: NonNegativeIntegerSchema,
  sessions_presence: NonNegativeIntegerSchema,
  sessions_total: NonNegativeIntegerSchema,
  external_subscribers: NonNegativeIntegerSchema,
  broadcast_avg_seconds: NonNegativeNumberSchema,
  broadcast_count: NonNegativeIntegerSchema,
  queue_avg_depth: NonNegativeNumberSchema,
  queue_max_depth: NonNegativeIntegerSchema,
  relay_queue_depth: NonNegativeIntegerSchema,
  relay_retry_total: NonNegativeIntegerSchema,
  relay_retry_append: NonNegativeIntegerSchema,
  relay_retry_broadcast: NonNegativeIntegerSchema,
  relay_drop_total: NonNegativeIntegerSchema,
  relay_drop_queue: NonNegativeIntegerSchema,
  relay_drop_append: NonNegativeIntegerSchema,
  relay_drop_broadcast: NonNegativeIntegerSchema,
  hot_sessions: Schema.Array(HotSessionSchema),
})

const GrpcSchema = Schema.Struct({
  configured: Schema.Boolean,
  listening: Schema.Boolean,
  port: PortSchema,
  active_streams: NonNegativeIntegerSchema,
  subscribers: NonNegativeIntegerSchema,
  heartbeat_avg_seconds: NonNegativeNumberSchema,
  events_delivered: NonNegativeIntegerSchema,
  events_dropped: NonNegativeIntegerSchema,
})

const WebsocketDeliverySchema = Schema.Struct({
  bytes_cache_hits: NonNegativeIntegerSchema,
  bytes_cache_misses: NonNegativeIntegerSchema,
  client_acks: NonNegativeIntegerSchema,
  throttled_deliveries: NonNegativeIntegerSchema,
  client_buffered_bytes_sum: NonNegativeNumberSchema,
  client_buffered_bytes_count: NonNegativeIntegerSchema,
})

const WebsocketSchema = Schema.Struct({
  configured: Schema.Boolean,
  listening: Schema.Boolean,
  mode: Schema.Literal('same_origin'),
  sessions: NonNegativeIntegerSchema,
  relay_source: Schema.Literal('sse_external_subscriber'),
  delivery: WebsocketDeliverySchema,
})

const HttpRateLimitResponseSchema = Schema.Struct({
  protocol: Schema.Literal('h1', 'h2'),
  scope: Schema.Literal('client_ip', 'agent', 'sse_connection'),
  total: NonNegativeIntegerSchema,
})

export type HttpRateLimitResponse = Schema.Schema.Type<
  typeof HttpRateLimitResponseSchema
>

const HttpListenerSchema = Schema.Struct({
  mode: Schema.Literal('unknown', 'h1', 'h2', 'auto'),
  status: Schema.Literal(
    'not_started',
    'listening',
    'stopped',
    'accept_error',
  ),
  active_connections: NonNegativeIntegerSchema,
  accepted_total: NonNegativeIntegerSchema,
  accept_errors_total: NonNegativeIntegerSchema,
  rate_limit_responses_total: NonNegativeIntegerSchema,
  rate_limit_responses: Schema.Array(HttpRateLimitResponseSchema),
  last_accept_unix: Schema.OptionFromNullOr(NonNegativeNumberSchema),
  last_accept_age_seconds: Schema.OptionFromNullOr(NonNegativeNumberSchema),
  last_error: Schema.OptionFromNullOr(Schema.String),
})

export type HttpListener = Schema.Schema.Type<typeof HttpListenerSchema>

const StreamableHttpSchema = Schema.Struct({
  endpoint: Schema.Literal('/mcp'),
  observer_stream: Schema.Literal('/mcp?sse_kind=observer'),
  presence_stream: Schema.Literal('/events/presence'),
  supports_post: Schema.Literal(true),
  supports_sse_upgrade: Schema.Literal(true),
  auth_rejects_total: NonNegativeIntegerSchema,
})

const Http2Schema = Schema.Union(
  Schema.Struct({
    listener_mode: Schema.Literal('auto'),
    multiplex_ready: Schema.Literal(true),
  }),
  Schema.Struct({
    listener_mode: Schema.Literal('h1_only'),
    multiplex_ready: Schema.Literal(false),
  }),
  Schema.Struct({
    listener_mode: Schema.Literal('h2_only'),
    multiplex_ready: Schema.Literal(true),
  }),
)

const AgentHealthSchema = Schema.Struct({
  stale_total: NonNegativeIntegerSchema,
  lifecycle_dispatch_rejections_total: NonNegativeIntegerSchema,
})

const ProjectionDiagnosticsSchema = Schema.Struct({
  source: Schema.Literal('cached_surface'),
  cache_state: Schema.Literal('initializing', 'fresh', 'stale'),
  last_success_at: Schema.OptionFromNullOr(Schema.String),
  last_attempt_at: Schema.OptionFromNullOr(Schema.String),
  last_error_at: Schema.OptionFromNullOr(Schema.String),
  stale_reason: Schema.OptionFromNullOr(Schema.String),
  stale_age_ms: Schema.OptionFromNullOr(NonNegativeIntegerSchema),
})

const TransportHealthReadySchema = Schema.Struct({
  http_listener: HttpListenerSchema,
  summary: SummarySchema,
  sse: SseOuterSchema,
  grpc: GrpcSchema,
  websocket: WebsocketSchema,
  streamable_http: StreamableHttpSchema,
  http2: Http2Schema,
  agent_health: AgentHealthSchema,
  generated_at: Schema.NonEmptyString,
  projection_diagnostics: ProjectionDiagnosticsSchema,
})

const TransportHealthInitializingSchema = Schema.Struct({
  status: Schema.Literal('initializing'),
  generated_at: Schema.NonEmptyString,
  message: Schema.NonEmptyString,
  projection_diagnostics: ProjectionDiagnosticsSchema,
})

export const TransportHealthSnapshotSchema = Schema.Union(
  TransportHealthReadySchema,
  TransportHealthInitializingSchema,
)

export type TransportHealthData = Schema.Schema.Type<
  typeof TransportHealthReadySchema
>
export type TransportHealthSnapshot = Schema.Schema.Type<
  typeof TransportHealthSnapshotSchema
>

export function isTransportHealthReady(
  snapshot: TransportHealthSnapshot,
): snapshot is TransportHealthData {
  return !('status' in snapshot)
}

export class TransportHealthSchemaDriftError extends Data.TaggedError(
  'TransportHealthSchemaDriftError',
)<{
  readonly domain: 'transport-health'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(
  error: ParseResult.ParseError,
): TransportHealthSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new TransportHealthSchemaDriftError({
    domain: 'transport-health',
    issues,
    message: `transport-health schema drift: ${details}`,
  })
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeTransportHealthData(
  data: unknown,
): Effect.Effect<TransportHealthSnapshot, TransportHealthSchemaDriftError> {
  return Schema.decodeUnknown(
    TransportHealthSnapshotSchema,
    STRICT_PARSE_OPTIONS,
  )(data).pipe(Effect.mapError(schemaDriftError))
}
