import { describe, it, expect } from 'vitest'
import { decodeTransportHealthData } from './transport-health'

/** Minimal valid raw payload with all required sub-objects. */
function minimalRaw(overrides: Record<string, unknown> = {}) {
  return {
    summary: { primary_path: 'sse', queue_pressure: 'normal' },
    sse: {},
    grpc: {},
    websocket: {},
    webrtc: {},
    streamable_http: {},
    http2: {},
    cluster: {},
    agent_health: {},
    generated_at: '2026-04-17T10:00:00Z',
    ...overrides,
  }
}

describe('decodeTransportHealthData', () => {
  it('returns null for null', () => {
    expect(decodeTransportHealthData(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(decodeTransportHealthData(undefined)).toBeNull()
  })

  it('returns null when generated_at is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ generated_at: undefined }))).toBeNull()
  })

  it('returns null when generated_at is empty', () => {
    expect(decodeTransportHealthData(minimalRaw({ generated_at: '' }))).toBeNull()
  })

  it('returns null when summary is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ summary: undefined }))).toBeNull()
  })

  it('returns null when sse is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ sse: undefined }))).toBeNull()
  })

  it('returns null when grpc is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ grpc: undefined }))).toBeNull()
  })

  it('returns null when websocket is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ websocket: undefined }))).toBeNull()
  })

  it('returns null when webrtc is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ webrtc: undefined }))).toBeNull()
  })

  it('returns null when streamable_http is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ streamable_http: undefined }))).toBeNull()
  })

  it('returns null when http2 is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ http2: undefined }))).toBeNull()
  })

  it('returns null when cluster is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ cluster: undefined }))).toBeNull()
  })

  it('returns null when agent_health is missing', () => {
    expect(decodeTransportHealthData(minimalRaw({ agent_health: undefined }))).toBeNull()
  })

  it('decodes minimal payload with defaults', () => {
    const result = decodeTransportHealthData(minimalRaw())
    expect(result).not.toBeNull()
    expect(result!.generated_at).toBe('2026-04-17T10:00:00Z')
    // summary defaults
    expect(result!.summary.primary_path).toBe('sse')
    expect(result!.summary.queue_pressure).toBe('normal')
    expect(result!.summary.recent_messages).toBeNull()
    expect(result!.summary.recent_messages_available).toBe(false)
    expect(result!.summary.external_fanout_targets).toBe(0)
    // sse defaults
    expect(result!.sse.sessions_total).toBe(0)
    expect(result!.sse.sessions_presence).toBe(0)
    expect(result!.sse.relay_queue_depth).toBe(0)
    expect(result!.sse.relay_retry_total).toBe(0)
    expect(result!.sse.relay_drop_total).toBe(0)
    expect(result!.sse.hot_sessions).toEqual([])
    // grpc defaults
    expect(result!.grpc.enabled).toBe(false)
    expect(result!.grpc.port).toBe(0)
    // websocket defaults
    expect(result!.websocket.mode).toBe('unknown')
    // webrtc defaults
    expect(result!.webrtc.signaling_mode).toBe('unknown')
    // streamable_http defaults
    expect(result!.streamable_http.default_transport).toBe('unknown')
    expect(result!.streamable_http.presence_stream).toBe('/events/presence')
    // http2 defaults
    expect(result!.http2.listener_mode).toBe('unknown')
    // cluster defaults
    expect(result!.cluster.cluster).toBe('default')
    expect(result!.cluster.total_units).toBeNull()
    // agent_health defaults
    expect(result!.agent_health.stale_total).toBe(0)
    expect(result!.agent_health.lifecycle_dispatch_rejections_total).toBe(0)
    // projection_diagnostics not present
    expect(result!.projection_diagnostics).toBeUndefined()
  })

  it('decodes full payload with all fields', () => {
    const raw = minimalRaw({
      summary: {
        primary_path: 'grpc',
        queue_pressure: 'high',
        recent_messages: 42,
        recent_messages_available: true,
        recent_messages_source: 'grpc',
        external_fanout_targets: 3,
      },
      sse: {
        sessions_observer: 2,
        sessions_agent_stream: 1,
        sessions_presence: 1,
        sessions_total: 4,
        external_subscribers: 5,
        broadcast_avg_seconds: 0.5,
        broadcast_count: 100,
        queue_avg_depth: 2,
        queue_max_depth: 10,
        relay_queue_depth: 4,
        relay_retry_total: 6,
        relay_retry_append: 2,
        relay_retry_broadcast: 4,
        relay_drop_total: 3,
        relay_drop_queue: 1,
        relay_drop_append: 1,
        relay_drop_broadcast: 1,
        hot_sessions: [
          { session_id: 'sess-1', kind: 'observer', queue_depth: 5, last_event_id: 99, idle_seconds: 3 },
          { session_id: 'sess-2', kind: 'agent_stream', queue_depth: 0, last_event_id: 50, idle_seconds: 30 },
        ],
      },
      grpc: {
        enabled: true,
        configured: true,
        listening: true,
        port: 50051,
        active_streams: 4,
        subscribers: 10,
        heartbeat_avg_seconds: 1.2,
        events_delivered: 500,
      },
      websocket: {
        enabled: true,
        configured: true,
        listening: false,
        listen_status: 'initializing',
        mode: 'same_origin',
        endpoint: '/ws',
        sessions: 2,
        relay_source: 'sse',
      },
      webrtc: {
        enabled: false,
        configured: false,
        signaling_available: false,
        signaling_mode: 'none',
        pending_offers: 0,
        active_peers: 0,
        live_connections: 0,
        connected_channels: 0,
        ice_server_count: 2,
      },
      streamable_http: {
        endpoint: '/mcp',
        observer_stream: '/mcp?sse_kind=observer',
        presence_stream: '/events/presence',
        managed_endpoint: '/mcp/managed',
        operator_endpoint: '/mcp/operator',
        delete_endpoint: '/mcp',
        default_transport: 'streamable-http',
        supports_post: true,
        supports_sse_upgrade: true,
        supports_delete: true,
      },
      http2: {
        listener_mode: 'h2c',
        multiplex_ready: true,
        prior_knowledge_path: '/mcp',
      },
      cluster: {
        cluster: 'prod',
        workspace_id: 'workspace-1',
        topology_available: true,
        topology_source: 'file',
        total_units: 5,
        managed_units: 5,
        live_agents: 3,
        active_operations: 1,
        stale_units: 0,
      },
      agent_health: { stale_total: 2, lifecycle_dispatch_rejections_total: 5 },
    })
    const result = decodeTransportHealthData(raw)
    expect(result!.summary.primary_path).toBe('grpc')
    expect(result!.summary.recent_messages).toBe(42)
    expect(result!.sse.sessions_total).toBe(4)
    expect(result!.sse.sessions_presence).toBe(1)
    expect(result!.sse.relay_queue_depth).toBe(4)
    expect(result!.sse.relay_retry_total).toBe(6)
    expect(result!.sse.relay_drop_total).toBe(3)
    expect(result!.sse.hot_sessions).toHaveLength(2)
    expect(result!.sse.hot_sessions[0]!.session_id).toBe('sess-1')
    expect(result!.sse.hot_sessions[0]!.kind).toBe('observer')
    expect(result!.grpc.enabled).toBe(true)
    expect(result!.grpc.port).toBe(50051)
    expect(result!.websocket.mode).toBe('same_origin')
    expect(result!.websocket.endpoint).toBe('/ws')
    expect(result!.websocket.listen_status).toBe('initializing')
    expect(result!.webrtc.ice_server_count).toBe(2)
    expect(result!.streamable_http.supports_post).toBe(true)
    expect(result!.streamable_http.presence_stream).toBe('/events/presence')
    expect(result!.http2.multiplex_ready).toBe(true)
    expect(result!.cluster.total_units).toBe(5)
    expect(result!.cluster.live_agents).toBe(3)
    expect(result!.agent_health.stale_total).toBe(2)
    expect(result!.agent_health.lifecycle_dispatch_rejections_total).toBe(5)
  })

  it('decodes hot_sessions with defaults', () => {
    const raw = minimalRaw({
      sse: { hot_sessions: [{ session_id: 's1' }] },
    })
    const result = decodeTransportHealthData(raw)
    const hs = result!.sse.hot_sessions
    expect(hs).toHaveLength(1)
    expect(hs[0]!.session_id).toBe('s1')
    expect(hs[0]!.kind).toBe('unknown')
    expect(hs[0]!.queue_depth).toBe(0)
    expect(hs[0]!.idle_seconds).toBe(0)
  })

  it('skips hot_session without session_id', () => {
    const raw = minimalRaw({
      sse: { hot_sessions: [{ kind: 'observer' }, { session_id: 's1' }] },
    })
    const result = decodeTransportHealthData(raw)
    expect(result!.sse.hot_sessions).toHaveLength(1)
  })

  it('decodes projection_diagnostics when present', () => {
    const raw = minimalRaw({
      projection_diagnostics: {
        source: 'keeper_poll',
        cache_state: 'warm',
        last_success_at: '2026-04-17T09:00:00Z',
        last_attempt_at: '2026-04-17T09:00:01Z',
        last_error_at: null,
        stale_reason: null,
        stale_age_ms: 5000,
      },
    })
    const result = decodeTransportHealthData(raw)
    const pd = result!.projection_diagnostics!
    expect(pd.source).toBe('keeper_poll')
    expect(pd.cache_state).toBe('warm')
    expect(pd.last_success_at).toBe('2026-04-17T09:00:00Z')
    expect(pd.last_error_at).toBeNull()
    expect(pd.stale_age_ms).toBe(5000)
  })

  it('omits projection_diagnostics when not present', () => {
    const result = decodeTransportHealthData(minimalRaw())
    expect(result!.projection_diagnostics).toBeUndefined()
  })

  it('handles cluster with null numeric fields', () => {
    const raw = minimalRaw({
      cluster: { total_units: null, live_agents: null },
    })
    const result = decodeTransportHealthData(raw)
    expect(result!.cluster.total_units).toBeNull()
    expect(result!.cluster.live_agents).toBeNull()
  })
})
