// Transport health schema — schema-at-boundary for
// `GET /api/v1/dashboard/transport-health`.
//
// The largest endpoint on the dashboard: 10 nested transport surfaces
// (summary, sse, grpc, websocket, webrtc, streamable_http, http2,
// cluster, agent_health, plus optional projection_diagnostics). The
// prior hand-rolled decoder returned `null` if ANY of the 9 required
// subsections or `generated_at` was missing — this PR preserves that
// contract via the thin null-returning wrapper in `api/transport-health.ts`.
//
// Uses the shared `SchemaDriftError` base landed in #7732.

import {
  boolean,
  check,
  fallback,
  nullable,
  number,
  object,
  optional,
  pipe,
  safeParse,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

// --- Hot session (per-entry lenient in sse.hot_sessions) ---

const HotSessionSchema = object({
  session_id: string(),
  kind: fallback(string(), 'unknown'),
  queue_depth: fallback(number(), 0),
  last_event_id: fallback(number(), 0),
  idle_seconds: fallback(number(), 0),
})

export type HotSession = InferOutput<typeof HotSessionSchema>

// --- Subsection schemas (each field uses fallback matching the prior
//     `asString(raw.X, DEFAULT)` / `asNumber(raw.X, 0)` decoder) ---

const SummarySchema = object({
  primary_path: fallback(string(), 'unknown'),
  queue_pressure: fallback(string(), 'unknown'),
  // `asNumber(x) ?? null` — absent/non-number → null, not undefined.
  recent_messages: fallback(nullable(number()), null),
  recent_messages_available: fallback(boolean(), false),
  recent_messages_source: fallback(string(), 'unknown'),
  external_fanout_targets: fallback(number(), 0),
})

const SseOuterSchema = object({
  sessions_observer: fallback(number(), 0),
  sessions_coordinator: fallback(number(), 0),
  sessions_presence: fallback(number(), 0),
  sessions_total: fallback(number(), 0),
  external_subscribers: fallback(number(), 0),
  broadcast_avg_seconds: fallback(number(), 0),
  broadcast_count: fallback(number(), 0),
  queue_avg_depth: fallback(number(), 0),
  queue_max_depth: fallback(number(), 0),
  relay_queue_depth: fallback(number(), 0),
  relay_retry_total: fallback(number(), 0),
  relay_retry_append: fallback(number(), 0),
  relay_retry_broadcast: fallback(number(), 0),
  relay_drop_total: fallback(number(), 0),
  relay_drop_queue: fallback(number(), 0),
  relay_drop_append: fallback(number(), 0),
  relay_drop_broadcast: fallback(number(), 0),
  // Lenient per-entry on hot_sessions handled in parseSse below.
  hot_sessions: optional(unknown()),
})

interface SseSection {
  sessions_observer: number
  sessions_coordinator: number
  sessions_presence: number
  sessions_total: number
  external_subscribers: number
  broadcast_avg_seconds: number
  broadcast_count: number
  queue_avg_depth: number
  queue_max_depth: number
  relay_queue_depth: number
  relay_retry_total: number
  relay_retry_append: number
  relay_retry_broadcast: number
  relay_drop_total: number
  relay_drop_queue: number
  relay_drop_append: number
  relay_drop_broadcast: number
  hot_sessions: HotSession[]
}

const GrpcSchema = object({
  enabled: fallback(boolean(), false),
  configured: fallback(boolean(), false),
  listening: fallback(boolean(), false),
  port: fallback(number(), 0),
  active_streams: fallback(number(), 0),
  subscribers: fallback(number(), 0),
  heartbeat_avg_seconds: fallback(number(), 0),
  events_delivered: fallback(number(), 0),
  events_dropped: fallback(number(), 0),
})

// Diagnostic counters for the WS delivery path.  Each field falls back
// to 0 so this remains forward-compatible with servers that have not
// yet landed the corresponding Prometheus metric (e.g. a dashboard
// pointed at an older build should not surface schema errors, it
// should show zeroes and let the operator know the metric is absent).
const WebsocketDeliverySchema = object({
  parse_cache_hits: fallback(number(), 0),
  parse_cache_misses: fallback(number(), 0),
  bytes_cache_hits: fallback(number(), 0),
  bytes_cache_misses: fallback(number(), 0),
  client_acks: fallback(number(), 0),
  throttled_deliveries: fallback(number(), 0),
  client_buffered_bytes_sum: fallback(number(), 0),
  client_buffered_bytes_count: fallback(number(), 0),
})

const WebsocketSchema = object({
  enabled: fallback(boolean(), false),
  configured: fallback(boolean(), false),
  listening: fallback(boolean(), false),
  mode: fallback(string(), 'unknown'),
  port: fallback(number(), 0),
  sessions: fallback(number(), 0),
  relay_source: fallback(string(), 'unknown'),
  delivery: fallback(WebsocketDeliverySchema, {
    parse_cache_hits: 0,
    parse_cache_misses: 0,
    bytes_cache_hits: 0,
    bytes_cache_misses: 0,
    client_acks: 0,
    throttled_deliveries: 0,
    client_buffered_bytes_sum: 0,
    client_buffered_bytes_count: 0,
  }),
})

const WebrtcSchema = object({
  enabled: fallback(boolean(), false),
  configured: fallback(boolean(), false),
  signaling_available: fallback(boolean(), false),
  signaling_mode: fallback(string(), 'unknown'),
  pending_offers: fallback(number(), 0),
  active_peers: fallback(number(), 0),
  live_connections: fallback(number(), 0),
  connected_channels: fallback(number(), 0),
  ice_server_count: fallback(number(), 0),
})

const StreamableHttpSchema = object({
  endpoint: fallback(string(), '/mcp'),
  observer_stream: fallback(string(), '/mcp?sse_kind=observer'),
  presence_stream: fallback(string(), '/events/presence'),
  managed_endpoint: fallback(string(), '/mcp/managed'),
  operator_endpoint: fallback(string(), '/mcp/operator'),
  delete_endpoint: fallback(string(), '/mcp'),
  legacy_sse_endpoint: fallback(string(), '/sse'),
  legacy_messages_endpoint: fallback(string(), '/messages'),
  default_transport: fallback(string(), 'unknown'),
  supports_post: fallback(boolean(), false),
  supports_sse_upgrade: fallback(boolean(), false),
  supports_delete: fallback(boolean(), false),
})

const Http2Schema = object({
  listener_mode: fallback(string(), 'unknown'),
  multiplex_ready: fallback(boolean(), false),
  prior_knowledge_path: fallback(string(), '/mcp'),
})

const ClusterSchema = object({
  cluster: fallback(string(), 'default'),
  room_id: fallback(string(), 'default'),
  topology_available: fallback(boolean(), false),
  topology_source: fallback(string(), 'unknown'),
  // These five use `asNumber(x) ?? null` — absent → null, not undefined.
  total_units: fallback(nullable(number()), null),
  managed_units: fallback(nullable(number()), null),
  live_agents: fallback(nullable(number()), null),
  active_operations: fallback(nullable(number()), null),
  stale_units: fallback(nullable(number()), null),
})

const AgentHealthSchema = object({
  stale_total: fallback(number(), 0),
  lifecycle_dispatch_rejections_total: fallback(number(), 0),
})

// `projection_diagnostics` is only present when the backend explicitly
// includes it. When omitted, downstream sees `undefined` (matches prior
// `projectionDiagnostics ? {...} : undefined`).
const ProjectionDiagnosticsSchema = object({
  source: fallback(string(), 'unknown'),
  cache_state: fallback(string(), 'unknown'),
  // Prior decoder: `asString(x) ?? null` — absent/non-string → null.
  last_success_at: fallback(nullable(string()), null),
  last_attempt_at: fallback(nullable(string()), null),
  last_error_at: fallback(nullable(string()), null),
  stale_reason: fallback(nullable(string()), null),
  stale_age_ms: fallback(nullable(number()), null),
})

// --- Outer schema: all 9 subsections required + generated_at non-empty ---

const TransportHealthOuterSchema = object({
  summary: SummarySchema,
  sse: SseOuterSchema,
  grpc: GrpcSchema,
  websocket: WebsocketSchema,
  webrtc: WebrtcSchema,
  streamable_http: StreamableHttpSchema,
  http2: Http2Schema,
  cluster: ClusterSchema,
  agent_health: AgentHealthSchema,
  // Prior decoder: `if (!generatedAt) return null` — empty string must
  // also cause rejection, matching that guard exactly.
  generated_at: pipe(
    string(),
    check(s => s.length > 0, 'generated_at must be non-empty'),
  ),
  projection_diagnostics: optional(ProjectionDiagnosticsSchema),
})

export interface TransportHealthData {
  summary: InferOutput<typeof SummarySchema>
  sse: SseSection
  grpc: InferOutput<typeof GrpcSchema>
  websocket: InferOutput<typeof WebsocketSchema>
  webrtc: InferOutput<typeof WebrtcSchema>
  streamable_http: InferOutput<typeof StreamableHttpSchema>
  http2: InferOutput<typeof Http2Schema>
  cluster: InferOutput<typeof ClusterSchema>
  agent_health: InferOutput<typeof AgentHealthSchema>
  generated_at: string
  projection_diagnostics?: InferOutput<typeof ProjectionDiagnosticsSchema>
}

export class TransportHealthSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('transport-health', issues)
  }
}

function parseSseHotSessions(raw: unknown): HotSession[] {
  if (!Array.isArray(raw)) return []
  const out: HotSession[] = []
  for (const item of raw) {
    const parsed = safeParse(HotSessionSchema, item, { abortEarly: true })
    if (parsed.success) out.push(parsed.output)
  }
  return out
}

export function parseTransportHealthData(data: unknown): TransportHealthData {
  const outer = parseOrThrow(
    TransportHealthSchemaDriftError,
    TransportHealthOuterSchema,
    data,
  )
  return {
    summary: outer.summary,
    sse: {
      sessions_observer: outer.sse.sessions_observer,
      sessions_coordinator: outer.sse.sessions_coordinator,
      sessions_presence: outer.sse.sessions_presence,
      sessions_total: outer.sse.sessions_total,
      external_subscribers: outer.sse.external_subscribers,
      broadcast_avg_seconds: outer.sse.broadcast_avg_seconds,
      broadcast_count: outer.sse.broadcast_count,
      queue_avg_depth: outer.sse.queue_avg_depth,
      queue_max_depth: outer.sse.queue_max_depth,
      relay_queue_depth: outer.sse.relay_queue_depth,
      relay_retry_total: outer.sse.relay_retry_total,
      relay_retry_append: outer.sse.relay_retry_append,
      relay_retry_broadcast: outer.sse.relay_retry_broadcast,
      relay_drop_total: outer.sse.relay_drop_total,
      relay_drop_queue: outer.sse.relay_drop_queue,
      relay_drop_append: outer.sse.relay_drop_append,
      relay_drop_broadcast: outer.sse.relay_drop_broadcast,
      hot_sessions: parseSseHotSessions(outer.sse.hot_sessions),
    },
    grpc: outer.grpc,
    websocket: outer.websocket,
    webrtc: outer.webrtc,
    streamable_http: outer.streamable_http,
    http2: outer.http2,
    cluster: outer.cluster,
    agent_health: outer.agent_health,
    generated_at: outer.generated_at,
    projection_diagnostics: outer.projection_diagnostics,
  }
}
