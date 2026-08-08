// Transport health schema — schema-at-boundary for
// `GET /api/v1/dashboard/transport-health`.
//
// Every field below is emitted by the current cached transport-health producer.
//
import {
  array,
  boolean,
  check,
  literal,
  nullable,
  number,
  strictObject,
  pipe,
  string,
  union,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

// --- Hot session ---

const NonNegativeNumberSchema = pipe(
  number(),
  check((value: number) => Number.isFinite(value), 'value must be finite'),
  check((value: number) => value >= 0, 'value must be non-negative'),
)

const NonNegativeIntegerSchema = pipe(
  NonNegativeNumberSchema,
  check((value: number) => Number.isInteger(value), 'value must be an integer'),
)

const PortSchema = pipe(
  NonNegativeIntegerSchema,
  check(
    (value: number) => value > 0 && value <= 65535,
    'port must be in 1..65535',
  ),
)

const HotSessionSchema = strictObject({
  session_id: pipe(
    string(),
    check((value) => value.length > 0, 'session_id must be non-empty'),
  ),
  kind: union([
    literal('observer'),
    literal('agent_stream'),
    literal('presence'),
  ]),
  queue_depth: NonNegativeIntegerSchema,
  last_event_id: NonNegativeIntegerSchema,
  idle_seconds: NonNegativeNumberSchema,
})

export type HotSession = InferOutput<typeof HotSessionSchema>

// --- Subsection schemas ---

const SummarySchema = strictObject({
  primary_path: union([
    literal('webrtc_datachannel'),
    literal('grpc_subscribe'),
    literal('websocket'),
    literal('sse'),
    literal('streamable_http'),
  ]),
  queue_pressure: union([literal('steady'), literal('watch'), literal('high')]),
  external_fanout_targets: NonNegativeIntegerSchema,
})

const SseOuterSchema = strictObject({
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
  hot_sessions: array(HotSessionSchema),
})

const GrpcSchema = strictObject({
  configured: boolean(),
  listening: boolean(),
  port: PortSchema,
  active_streams: NonNegativeIntegerSchema,
  subscribers: NonNegativeIntegerSchema,
  heartbeat_avg_seconds: NonNegativeNumberSchema,
  events_delivered: NonNegativeIntegerSchema,
  events_dropped: NonNegativeIntegerSchema,
})

const WebsocketDeliverySchema = strictObject({
  bytes_cache_hits: NonNegativeIntegerSchema,
  bytes_cache_misses: NonNegativeIntegerSchema,
  client_acks: NonNegativeIntegerSchema,
  throttled_deliveries: NonNegativeIntegerSchema,
  client_buffered_bytes_sum: NonNegativeNumberSchema,
  client_buffered_bytes_count: NonNegativeIntegerSchema,
})

const WebsocketSchema = strictObject({
  configured: boolean(),
  listening: boolean(),
  mode: literal('standalone'),
  port: PortSchema,
  sessions: NonNegativeIntegerSchema,
  relay_source: literal('sse_external_subscriber'),
  delivery: WebsocketDeliverySchema,
})

const WebrtcSchema = strictObject({
  configured: boolean(),
  signaling_available: boolean(),
  signaling_mode: literal('shared_http'),
  pending_offers: NonNegativeIntegerSchema,
  active_peers: NonNegativeIntegerSchema,
  live_connections: NonNegativeIntegerSchema,
  connected_channels: NonNegativeIntegerSchema,
  ice_server_count: NonNegativeIntegerSchema,
})

const StreamableHttpSchema = strictObject({
  endpoint: literal('/mcp'),
  observer_stream: literal('/mcp?sse_kind=observer'),
  presence_stream: literal('/events/presence'),
  supports_post: literal(true),
  supports_sse_upgrade: literal(true),
})

const Http2Schema = union([
  strictObject({
    listener_mode: literal('auto'),
    multiplex_ready: literal(true),
  }),
  strictObject({
    listener_mode: literal('h1_only'),
    multiplex_ready: literal(false),
  }),
  strictObject({
    listener_mode: literal('h2_only'),
    multiplex_ready: literal(true),
  }),
])

const AgentHealthSchema = strictObject({
  stale_total: NonNegativeIntegerSchema,
  lifecycle_dispatch_rejections_total: NonNegativeIntegerSchema,
})

const ProjectionDiagnosticsSchema = strictObject({
  source: literal('cached_surface'),
  cache_state: union([
    literal('initializing'),
    literal('fresh'),
    literal('stale'),
  ]),
  last_success_at: nullable(string()),
  last_attempt_at: nullable(string()),
  last_error_at: nullable(string()),
  stale_reason: nullable(string()),
  stale_age_ms: nullable(NonNegativeIntegerSchema),
})

// --- Outer schemas ---

const TransportHealthReadySchema = strictObject({
  summary: SummarySchema,
  sse: SseOuterSchema,
  grpc: GrpcSchema,
  websocket: WebsocketSchema,
  webrtc: WebrtcSchema,
  streamable_http: StreamableHttpSchema,
  http2: Http2Schema,
  agent_health: AgentHealthSchema,
  generated_at: pipe(
    string(),
    check((s) => s.length > 0, 'generated_at must be non-empty'),
  ),
  projection_diagnostics: ProjectionDiagnosticsSchema,
})

const GeneratedAtSchema = pipe(
  string(),
  check((s) => s.length > 0, 'generated_at must be non-empty'),
)

const TransportHealthInitializingSchema = strictObject({
  status: literal('initializing'),
  generated_at: GeneratedAtSchema,
  message: pipe(
    string(),
    check((s) => s.length > 0, 'message must be non-empty'),
  ),
  projection_diagnostics: ProjectionDiagnosticsSchema,
})

const TransportHealthSnapshotSchema = union([
  TransportHealthReadySchema,
  TransportHealthInitializingSchema,
])

export type TransportHealthData = InferOutput<typeof TransportHealthReadySchema>
export type TransportHealthSnapshot = InferOutput<
  typeof TransportHealthSnapshotSchema
>

export function isTransportHealthReady(
  snapshot: TransportHealthSnapshot,
): snapshot is TransportHealthData {
  return !('status' in snapshot)
}

export class TransportHealthSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('transport-health', issues)
  }
}

export function parseTransportHealthData(data: unknown): TransportHealthSnapshot {
  return parseOrThrow(
    TransportHealthSchemaDriftError,
    TransportHealthSnapshotSchema,
    data,
  )
}
