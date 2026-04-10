import { get } from './core'
import {
  asBoolean,
  asNumber,
  asRecordArray,
  asString,
  isRecord,
} from '../components/common/normalize'

export interface HotSession {
  session_id: string
  kind: string
  queue_depth: number
  last_event_id: number
  idle_seconds: number
}

export interface TransportHealthData {
  summary: {
    primary_path: string
    queue_pressure: string
    recent_messages: number | null
    recent_messages_available: boolean
    recent_messages_source: string
    external_fanout_targets: number
  }
  sse: {
    sessions_observer: number
    sessions_coordinator: number
    sessions_total: number
    external_subscribers: number
    broadcast_avg_seconds: number
    broadcast_count: number
    queue_avg_depth: number
    queue_max_depth: number
    hot_sessions: HotSession[]
  }
  grpc: {
    enabled: boolean
    configured: boolean
    listening: boolean
    port: number
    active_streams: number
    subscribers: number
    heartbeat_avg_seconds: number
    events_delivered: number
  }
  websocket: {
    enabled: boolean
    configured: boolean
    listening: boolean
    mode: string
    port: number
    sessions: number
    relay_source: string
  }
  webrtc: {
    enabled: boolean
    configured: boolean
    signaling_available: boolean
    signaling_mode: string
    pending_offers: number
    active_peers: number
    live_connections: number
    connected_channels: number
    ice_server_count: number
  }
  streamable_http: {
    endpoint: string
    observer_stream: string
    managed_endpoint: string
    operator_endpoint: string
    delete_endpoint: string
    legacy_sse_endpoint: string
    legacy_messages_endpoint: string
    default_transport: string
    supports_post: boolean
    supports_sse_upgrade: boolean
    supports_delete: boolean
  }
  http2: {
    listener_mode: string
    multiplex_ready: boolean
    prior_knowledge_path: string
  }
  cluster: {
    cluster: string
    room_id: string
    topology_available: boolean
    topology_source: string
    total_units: number | null
    managed_units: number | null
    live_agents: number | null
    active_operations: number | null
    stale_units: number | null
  }
  agent_health: {
    stale_total: number
  }
  generated_at: string
}

type AbortableRequestOptions = {
  signal?: AbortSignal
}

function decodeHotSession(raw: unknown): HotSession | null {
  if (!isRecord(raw)) return null
  const sessionId = asString(raw.session_id)
  if (!sessionId) return null
  return {
    session_id: sessionId,
    kind: asString(raw.kind, 'unknown'),
    queue_depth: asNumber(raw.queue_depth, 0),
    last_event_id: asNumber(raw.last_event_id, 0),
    idle_seconds: asNumber(raw.idle_seconds, 0),
  }
}

export function decodeTransportHealthData(raw: unknown): TransportHealthData | null {
  if (!isRecord(raw)) return null
  const summary = isRecord(raw.summary) ? raw.summary : null
  const sse = isRecord(raw.sse) ? raw.sse : null
  const grpc = isRecord(raw.grpc) ? raw.grpc : null
  const websocket = isRecord(raw.websocket) ? raw.websocket : null
  const webrtc = isRecord(raw.webrtc) ? raw.webrtc : null
  const streamableHttp = isRecord(raw.streamable_http) ? raw.streamable_http : null
  const http2 = isRecord(raw.http2) ? raw.http2 : null
  const cluster = isRecord(raw.cluster) ? raw.cluster : null
  const agentHealth = isRecord(raw.agent_health) ? raw.agent_health : null
  const generatedAt = asString(raw.generated_at)

  if (!summary || !sse || !grpc || !websocket || !webrtc || !streamableHttp || !http2 || !cluster || !agentHealth || !generatedAt) {
    return null
  }

  return {
    summary: {
      primary_path: asString(summary.primary_path, 'unknown'),
      queue_pressure: asString(summary.queue_pressure, 'unknown'),
      recent_messages: asNumber(summary.recent_messages) ?? null,
      recent_messages_available: asBoolean(summary.recent_messages_available, false),
      recent_messages_source: asString(summary.recent_messages_source, 'unknown'),
      external_fanout_targets: asNumber(summary.external_fanout_targets, 0),
    },
    sse: {
      sessions_observer: asNumber(sse.sessions_observer, 0),
      sessions_coordinator: asNumber(sse.sessions_coordinator, 0),
      sessions_total: asNumber(sse.sessions_total, 0),
      external_subscribers: asNumber(sse.external_subscribers, 0),
      broadcast_avg_seconds: asNumber(sse.broadcast_avg_seconds, 0),
      broadcast_count: asNumber(sse.broadcast_count, 0),
      queue_avg_depth: asNumber(sse.queue_avg_depth, 0),
      queue_max_depth: asNumber(sse.queue_max_depth, 0),
      hot_sessions: asRecordArray(sse.hot_sessions)
        .map(decodeHotSession)
        .filter((session): session is HotSession => session !== null),
    },
    grpc: {
      enabled: asBoolean(grpc.enabled, false),
      configured: asBoolean(grpc.configured, false),
      listening: asBoolean(grpc.listening, false),
      port: asNumber(grpc.port, 0),
      active_streams: asNumber(grpc.active_streams, 0),
      subscribers: asNumber(grpc.subscribers, 0),
      heartbeat_avg_seconds: asNumber(grpc.heartbeat_avg_seconds, 0),
      events_delivered: asNumber(grpc.events_delivered, 0),
    },
    websocket: {
      enabled: asBoolean(websocket.enabled, false),
      configured: asBoolean(websocket.configured, false),
      listening: asBoolean(websocket.listening, false),
      mode: asString(websocket.mode, 'unknown'),
      port: asNumber(websocket.port, 0),
      sessions: asNumber(websocket.sessions, 0),
      relay_source: asString(websocket.relay_source, 'unknown'),
    },
    webrtc: {
      enabled: asBoolean(webrtc.enabled, false),
      configured: asBoolean(webrtc.configured, false),
      signaling_available: asBoolean(webrtc.signaling_available, false),
      signaling_mode: asString(webrtc.signaling_mode, 'unknown'),
      pending_offers: asNumber(webrtc.pending_offers, 0),
      active_peers: asNumber(webrtc.active_peers, 0),
      live_connections: asNumber(webrtc.live_connections, 0),
      connected_channels: asNumber(webrtc.connected_channels, 0),
      ice_server_count: asNumber(webrtc.ice_server_count, 0),
    },
    streamable_http: {
      endpoint: asString(streamableHttp.endpoint, '/mcp'),
      observer_stream: asString(streamableHttp.observer_stream, '/mcp?sse_kind=observer'),
      managed_endpoint: asString(streamableHttp.managed_endpoint, '/mcp/managed'),
      operator_endpoint: asString(streamableHttp.operator_endpoint, '/mcp/operator'),
      delete_endpoint: asString(streamableHttp.delete_endpoint, '/mcp'),
      legacy_sse_endpoint: asString(streamableHttp.legacy_sse_endpoint, '/sse'),
      legacy_messages_endpoint: asString(streamableHttp.legacy_messages_endpoint, '/messages'),
      default_transport: asString(streamableHttp.default_transport, 'unknown'),
      supports_post: asBoolean(streamableHttp.supports_post, false),
      supports_sse_upgrade: asBoolean(streamableHttp.supports_sse_upgrade, false),
      supports_delete: asBoolean(streamableHttp.supports_delete, false),
    },
    http2: {
      listener_mode: asString(http2.listener_mode, 'unknown'),
      multiplex_ready: asBoolean(http2.multiplex_ready, false),
      prior_knowledge_path: asString(http2.prior_knowledge_path, '/mcp'),
    },
    cluster: {
      cluster: asString(cluster.cluster, 'default'),
      room_id: asString(cluster.room_id, 'default'),
      topology_available: asBoolean(cluster.topology_available, false),
      topology_source: asString(cluster.topology_source, 'unknown'),
      total_units: asNumber(cluster.total_units) ?? null,
      managed_units: asNumber(cluster.managed_units) ?? null,
      live_agents: asNumber(cluster.live_agents) ?? null,
      active_operations: asNumber(cluster.active_operations) ?? null,
      stale_units: asNumber(cluster.stale_units) ?? null,
    },
    agent_health: {
      stale_total: asNumber(agentHealth.stale_total, 0),
    },
    generated_at: generatedAt,
  }
}

export async function fetchTransportHealth(opts?: AbortableRequestOptions): Promise<TransportHealthData> {
  const raw = await get<Record<string, unknown>>('/api/v1/dashboard/transport-health', { signal: opts?.signal })
  const decoded = decodeTransportHealthData(raw)
  if (!decoded) {
    throw new Error('invalid transport health payload')
  }
  return decoded
}
