import { describe, expect, it } from 'vitest'
import {
  parseTransportHealthData,
  TransportHealthSchemaDriftError,
} from './transport-health'

describe('parseTransportHealthData', () => {
  const minimalValid = {
    summary: {},
    sse: {},
    grpc: {},
    websocket: {},
    webrtc: {},
    streamable_http: {},
    http2: {},
    cluster: {},
    agent_health: {},
    generated_at: '2024-01-01T00:00:00Z',
  }

  it('parses minimal valid data with all fallback defaults', () => {
    const result = parseTransportHealthData(minimalValid)
    expect(result.generated_at).toBe('2024-01-01T00:00:00Z')
    expect(result.summary.primary_path).toBe('unknown')
    expect(result.summary.recent_messages).toBeNull()
    expect(result.summary.recent_messages_available).toBe(false)
    expect(result.summary.external_fanout_targets).toBe(0)
    expect(result.sse.sessions_total).toBe(0)
    expect(result.sse.hot_sessions).toEqual([])
    expect(result.grpc.enabled).toBe(false)
    expect(result.grpc.port).toBe(0)
    expect(result.websocket.mode).toBe('unknown')
    expect(result.websocket.delivery.parse_cache_hits).toBe(0)
    expect(result.webrtc.signaling_mode).toBe('unknown')
    expect(result.streamable_http.endpoint).toBe('/mcp')
    expect(result.http2.listener_mode).toBe('unknown')
    expect(result.cluster.cluster).toBe('default')
    expect(result.cluster.total_units).toBeNull()
    expect(result.agent_health.stale_total).toBe(0)
    expect(result.projection_diagnostics).toBeUndefined()
  })

  it('throws TransportHealthSchemaDriftError when generated_at is empty', () => {
    expect(() =>
      parseTransportHealthData({
        ...minimalValid,
        generated_at: '',
      }),
    ).toThrow(TransportHealthSchemaDriftError)
  })

  it('throws TransportHealthSchemaDriftError when generated_at is missing', () => {
    const { generated_at: _, ...missing } = minimalValid
    expect(() => parseTransportHealthData(missing)).toThrow(
      TransportHealthSchemaDriftError,
    )
  })

  it('throws TransportHealthSchemaDriftError when a required subsection is missing', () => {
    const { grpc: _, ...missingGrpc } = minimalValid
    expect(() => parseTransportHealthData(missingGrpc)).toThrow(
      TransportHealthSchemaDriftError,
    )
  })

  it('parses hot_sessions filtering invalid entries', () => {
    const result = parseTransportHealthData({
      ...minimalValid,
      sse: {
        hot_sessions: [
          { session_id: 's1', kind: 'observer' },
          { session_id: 's2' },
          'invalid',
          { session_id: 's3', kind: 'coordinator', queue_depth: 5 },
        ],
      },
    })
    expect(result.sse.hot_sessions).toHaveLength(3)
    expect(result.sse.hot_sessions[0]).toEqual({
      session_id: 's1',
      kind: 'observer',
      queue_depth: 0,
      last_event_id: 0,
      idle_seconds: 0,
    })
    expect(result.sse.hot_sessions[1]).toEqual({
      session_id: 's2',
      kind: 'unknown',
      queue_depth: 0,
      last_event_id: 0,
      idle_seconds: 0,
    })
    expect(result.sse.hot_sessions[2]).toEqual({
      session_id: 's3',
      kind: 'coordinator',
      queue_depth: 5,
      last_event_id: 0,
      idle_seconds: 0,
    })
  })

  it('returns empty hot_sessions for non-array input', () => {
    const result = parseTransportHealthData({
      ...minimalValid,
      sse: { hot_sessions: 'not-array' },
    })
    expect(result.sse.hot_sessions).toEqual([])
  })

  it('parses projection_diagnostics when present', () => {
    const result = parseTransportHealthData({
      ...minimalValid,
      projection_diagnostics: {
        source: 'test-source',
        cache_state: 'warm',
        last_success_at: '2024-01-01T00:00:00Z',
        stale_reason: null,
      },
    })
    expect(result.projection_diagnostics).toBeDefined()
    expect(result.projection_diagnostics?.source).toBe('test-source')
    expect(result.projection_diagnostics?.cache_state).toBe('warm')
    expect(result.projection_diagnostics?.last_success_at).toBe('2024-01-01T00:00:00Z')
    expect(result.projection_diagnostics?.last_attempt_at).toBeNull()
    expect(result.projection_diagnostics?.last_error_at).toBeNull()
    expect(result.projection_diagnostics?.stale_reason).toBeNull()
    expect(result.projection_diagnostics?.stale_age_ms).toBeNull()
  })

  it('parses populated subsection fields', () => {
    const result = parseTransportHealthData({
      summary: {
        primary_path: '/events',
        queue_pressure: 'low',
        recent_messages: 42,
        recent_messages_available: true,
        recent_messages_source: 'memory',
        external_fanout_targets: 3,
      },
      sse: {
        sessions_observer: 1,
        sessions_coordinator: 2,
        sessions_presence: 3,
        sessions_total: 6,
        external_subscribers: 10,
        broadcast_avg_seconds: 0.5,
        broadcast_count: 100,
        queue_avg_depth: 2,
        queue_max_depth: 10,
        relay_queue_depth: 0,
        relay_retry_total: 1,
        relay_retry_append: 0,
        relay_retry_broadcast: 1,
        relay_drop_total: 0,
        relay_drop_queue: 0,
        relay_drop_append: 0,
        relay_drop_broadcast: 0,
      },
      grpc: {
        enabled: true,
        configured: true,
        listening: true,
        port: 50051,
        active_streams: 5,
        subscribers: 3,
        heartbeat_avg_seconds: 30,
        events_delivered: 1000,
        events_dropped: 2,
      },
      websocket: {
        enabled: true,
        configured: true,
        listening: true,
        mode: 'relay',
        port: 8080,
        sessions: 15,
        relay_source: 'sse',
        delivery: {
          parse_cache_hits: 100,
          parse_cache_misses: 5,
          bytes_cache_hits: 200,
          bytes_cache_misses: 10,
          client_acks: 95,
          throttled_deliveries: 2,
          client_buffered_bytes_sum: 1024,
          client_buffered_bytes_count: 10,
        },
      },
      webrtc: {
        enabled: true,
        configured: true,
        signaling_available: true,
        signaling_mode: 'auto',
        pending_offers: 0,
        active_peers: 4,
        live_connections: 2,
        connected_channels: 2,
        ice_server_count: 3,
      },
      streamable_http: {
        endpoint: '/mcp',
        observer_stream: '/mcp?sse_kind=observer',
        presence_stream: '/events/presence',
        managed_endpoint: '/mcp/managed',
        operator_endpoint: '/mcp/operator',
        delete_endpoint: '/mcp',
        legacy_sse_endpoint: '/sse',
        legacy_messages_endpoint: '/messages',
        default_transport: 'streamable_http',
        supports_post: true,
        supports_sse_upgrade: true,
        supports_delete: true,
      },
      http2: {
        listener_mode: 'prior_knowledge',
        multiplex_ready: true,
        prior_knowledge_path: '/mcp',
      },
      cluster: {
        cluster: 'alpha',
        room_id: 'room-1',
        topology_available: true,
        topology_source: 'consul',
        total_units: 10,
        managed_units: 8,
        live_agents: 6,
        active_operations: 4,
        stale_units: 0,
      },
      agent_health: {
        stale_total: 0,
        lifecycle_dispatch_rejections_total: 1,
      },
      generated_at: '2024-01-01T00:00:00Z',
    })

    expect(result.summary.primary_path).toBe('/events')
    expect(result.summary.recent_messages).toBe(42)
    expect(result.sse.sessions_total).toBe(6)
    expect(result.sse.broadcast_avg_seconds).toBe(0.5)
    expect(result.grpc.port).toBe(50051)
    expect(result.grpc.events_delivered).toBe(1000)
    expect(result.websocket.mode).toBe('relay')
    expect(result.websocket.delivery.client_acks).toBe(95)
    expect(result.webrtc.active_peers).toBe(4)
    expect(result.streamable_http.default_transport).toBe('streamable_http')
    expect(result.http2.multiplex_ready).toBe(true)
    expect(result.cluster.cluster).toBe('alpha')
    expect(result.cluster.total_units).toBe(10)
    expect(result.agent_health.lifecycle_dispatch_rejections_total).toBe(1)
  })

  it('parses nullable cluster fields as null when explicitly null', () => {
    const result = parseTransportHealthData({
      ...minimalValid,
      cluster: {
        total_units: null,
        managed_units: null,
        live_agents: null,
        active_operations: null,
        stale_units: null,
      },
    })
    expect(result.cluster.total_units).toBeNull()
    expect(result.cluster.managed_units).toBeNull()
    expect(result.cluster.live_agents).toBeNull()
    expect(result.cluster.active_operations).toBeNull()
    expect(result.cluster.stale_units).toBeNull()
  })
})
