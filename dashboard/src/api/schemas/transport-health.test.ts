import { describe, expect, it } from 'vitest'
import { Effect, Option } from 'effect'
import {
  decodeTransportHealthData,
  isTransportHealthReady,
  type TransportHealthData,
  TransportHealthSchemaDriftError,
} from './transport-health'

const currentWire = {
  http_listener: {
    mode: 'auto',
    status: 'listening',
    active_connections: 2,
    accepted_total: 11,
    accept_errors_total: 0,
    rate_limit_responses_total: 3,
    rate_limit_responses: [
      { protocol: 'h1', scope: 'client_ip', total: 2 },
      { protocol: 'h2', scope: 'agent', total: 1 },
    ],
    last_accept_unix: 1_725_000_000,
    last_accept_age_seconds: 0.25,
    last_error: null,
  },
  summary: {
    primary_path: 'streamable_http',
    queue_pressure: 'steady',
    external_fanout_targets: 0,
  },
  sse: {
    sessions_observer: 0,
    sessions_agent_stream: 0,
    sessions_presence: 0,
    sessions_total: 0,
    external_subscribers: 0,
    broadcast_avg_seconds: 0,
    broadcast_count: 0,
    queue_avg_depth: 0,
    queue_max_depth: 0,
    relay_queue_depth: 0,
    relay_retry_total: 0,
    relay_retry_append: 0,
    relay_retry_broadcast: 0,
    relay_drop_total: 0,
    relay_drop_queue: 0,
    relay_drop_append: 0,
    relay_drop_broadcast: 0,
    hot_sessions: [],
  },
  grpc: {
    configured: false,
    listening: false,
    port: 8936,
    active_streams: 0,
    subscribers: 0,
    heartbeat_avg_seconds: 0,
    events_delivered: 0,
    events_dropped: 0,
  },
  websocket: {
    configured: false,
    listening: false,
    mode: 'same_origin',
    sessions: 0,
    relay_source: 'sse_external_subscriber',
    delivery: {
      bytes_cache_hits: 0,
      bytes_cache_misses: 0,
      client_acks: 0,
      throttled_deliveries: 0,
      client_buffered_bytes_sum: 0,
      client_buffered_bytes_count: 0,
    },
  },
  streamable_http: {
    endpoint: '/mcp',
    observer_stream: '/mcp?sse_kind=observer',
    presence_stream: '/events/presence',
    supports_post: true,
    supports_sse_upgrade: true,
    auth_rejects_total: 4,
  },
  http2: {
    listener_mode: 'auto',
    multiplex_ready: true,
  },
  agent_health: {
    stale_total: 0,
    lifecycle_dispatch_rejections_total: 0,
  },
  generated_at: '2024-01-01T00:00:00Z',
  projection_diagnostics: {
    source: 'cached_surface',
    cache_state: 'fresh',
    last_success_at: '2024-01-01T00:00:00Z',
    last_attempt_at: null,
    last_error_at: null,
    stale_reason: null,
    stale_age_ms: null,
  },
}

function expectDrift(value: unknown): void {
  const error = Effect.runSync(Effect.flip(decodeTransportHealthData(value)))
  expect(error).toBeInstanceOf(TransportHealthSchemaDriftError)
  expect(error.message).toContain('transport-health schema drift')
}

function parseReady(value: unknown): TransportHealthData {
  const snapshot = Effect.runSync(decodeTransportHealthData(value))
  if (!isTransportHealthReady(snapshot)) {
    throw new Error('expected ready transport-health snapshot')
  }
  return snapshot
}

describe('decodeTransportHealthData', () => {
  it('decodes the complete current wire contract', () => {
    const result = parseReady(currentWire)
    expect(result.summary.primary_path).toBe('streamable_http')
    expect(result.sse.hot_sessions).toEqual([])
    expect(result.grpc.port).toBe(8936)
    expect(result.websocket.mode).toBe('same_origin')
    expect(result.http_listener.rate_limit_responses[0]).toEqual({
      protocol: 'h1',
      scope: 'client_ip',
      total: 2,
    })
    expect(result.streamable_http.auth_rejects_total).toBe(4)
    expect(result.http2.listener_mode).toBe('auto')
    expect(result.projection_diagnostics.source).toBe('cached_surface')
  })

  it('decodes the exact initializing cache envelope', () => {
    const result = Effect.runSync(decodeTransportHealthData({
      status: 'initializing',
      generated_at: '2024-01-01T00:00:00Z',
      message: 'Transport health data is warming up.',
      projection_diagnostics: {
        source: 'cached_surface',
        cache_state: 'initializing',
        last_success_at: null,
        last_attempt_at: null,
        last_error_at: null,
        stale_reason: null,
        stale_age_ms: null,
      },
    }))
    expect(isTransportHealthReady(result)).toBe(false)
    expect('status' in result && result.status).toBe('initializing')
  })

  it('converts wire nulls to Option once at the schema boundary', () => {
    const result = parseReady(currentWire)
    expect(Option.isSome(result.projection_diagnostics.last_success_at)).toBe(
      true,
    )
    expect(Option.isNone(result.projection_diagnostics.last_attempt_at)).toBe(
      true,
    )
    expect(Option.isNone(result.projection_diagnostics.stale_age_ms)).toBe(true)
    expect(Option.isNone(result.http_listener.last_error)).toBe(true)
  })

  it.each([
    ['generated_at', { ...currentWire, generated_at: '' }],
    ['summary', { ...currentWire, summary: undefined }],
    ['http_listener', { ...currentWire, http_listener: undefined }],
    ['grpc', { ...currentWire, grpc: undefined }],
    [
      'projection_diagnostics',
      { ...currentWire, projection_diagnostics: undefined },
    ],
    [
      'grpc.port primitive',
      { ...currentWire, grpc: { ...currentWire.grpc, port: '8936' } },
    ],
    [
      'negative grpc counter',
      { ...currentWire, grpc: { ...currentWire.grpc, subscribers: -1 } },
    ],
    [
      'infinite duration',
      {
        ...currentWire,
        sse: { ...currentWire.sse, broadcast_avg_seconds: Number.POSITIVE_INFINITY },
      },
    ],
    [
      'NaN duration',
      {
        ...currentWire,
        sse: { ...currentWire.sse, broadcast_avg_seconds: Number.NaN },
      },
    ],
    [
      'unknown grpc field',
      { ...currentWire, grpc: { ...currentWire.grpc, enabled: false } },
    ],
    [
      'summary primary_path',
      {
        ...currentWire,
        summary: { ...currentWire.summary, primary_path: 'unknown' },
      },
    ],
    [
      'summary queue_pressure',
      {
        ...currentWire,
        summary: { ...currentWire.summary, queue_pressure: 'low' },
      },
    ],
    [
      'websocket mode',
      {
        ...currentWire,
        websocket: { ...currentWire.websocket, mode: 'relay' },
      },
    ],
    [
      'streamable endpoint',
      {
        ...currentWire,
        streamable_http: { ...currentWire.streamable_http, endpoint: '/mcp-v2' },
      },
    ],
    [
      'streamable auth reject count',
      {
        ...currentWire,
        streamable_http: {
          ...currentWire.streamable_http,
          auth_rejects_total: undefined,
        },
      },
    ],
    [
      'HTTP rate-limit protocol',
      {
        ...currentWire,
        http_listener: {
          ...currentWire.http_listener,
          rate_limit_responses: [
            { protocol: 'h3', scope: 'agent', total: 1 },
          ],
        },
      },
    ],
    [
      'negative HTTP rate-limit count',
      {
        ...currentWire,
        http_listener: {
          ...currentWire.http_listener,
          rate_limit_responses: [
            { protocol: 'h1', scope: 'agent', total: -1 },
          ],
        },
      },
    ],
  ])('rejects invalid or missing %s', (_label, value) => {
    expectDrift(value)
  })

  it('accepts all three exact hot-session kinds', () => {
    const hotSessions = ['observer', 'agent_stream', 'presence'].map(
      (kind, index) => ({
        session_id: `session-${index}`,
        kind,
        queue_depth: index,
        last_event_id: index,
        idle_seconds: index + 0.5,
      }),
    )
    const result = parseReady({
      ...currentWire,
      sse: { ...currentWire.sse, hot_sessions: hotSessions },
    })
    expect(result.sse.hot_sessions).toHaveLength(3)
  })

  it.each([
    ['non-array', 'not-array'],
    ['missing field', [{ session_id: 's1', kind: 'observer' }]],
    [
      'unknown kind',
      [
        {
          session_id: 's1',
          kind: 'unknown',
          queue_depth: 0,
          last_event_id: 0,
          idle_seconds: 0,
        },
      ],
    ],
    [
      'fractional counter',
      [
        {
          session_id: 's1',
          kind: 'observer',
          queue_depth: 0.5,
          last_event_id: 0,
          idle_seconds: 0,
        },
      ],
    ],
    [
      'negative counter',
      [
        {
          session_id: 's1',
          kind: 'observer',
          queue_depth: 0,
          last_event_id: -1,
          idle_seconds: 0,
        },
      ],
    ],
    [
      'mixed invalid entry',
      [
        {
          session_id: 's1',
          kind: 'observer',
          queue_depth: 0,
          last_event_id: 0,
          idle_seconds: 0,
        },
        { session_id: 's2' },
      ],
    ],
  ])('rejects %s hot sessions as a whole', (_label, hot_sessions) => {
    expectDrift({
      ...currentWire,
      sse: { ...currentWire.sse, hot_sessions },
    })
  })

  it.each(['initializing', 'fresh', 'stale'])(
    'accepts %s cache state',
    (cache_state) => {
      const result = parseReady({
        ...currentWire,
        projection_diagnostics: {
          ...currentWire.projection_diagnostics,
          cache_state,
        },
      })
      expect(result.projection_diagnostics.cache_state).toBe(cache_state)
    },
  )

  it.each([
    ['source', { ...currentWire.projection_diagnostics, source: undefined }],
    [
      'unknown source',
      { ...currentWire.projection_diagnostics, source: 'live_metrics' },
    ],
    [
      'cache_state',
      { ...currentWire.projection_diagnostics, cache_state: undefined },
    ],
    [
      'unknown cache_state',
      { ...currentWire.projection_diagnostics, cache_state: 'warm' },
    ],
    [
      'nullable field type',
      { ...currentWire.projection_diagnostics, stale_age_ms: '10' },
    ],
  ])(
    'rejects invalid projection diagnostics %s',
    (_label, projection_diagnostics) => {
      expectDrift({ ...currentWire, projection_diagnostics })
    },
  )

  it('rejects a listener mode outside the closed wire vocabulary', () => {
    expectDrift({
      ...currentWire,
      http2: { listener_mode: 'h2c', multiplex_ready: true },
    })
  })

  it('rejects readiness that contradicts the listener mode', () => {
    expectDrift({
      ...currentWire,
      http2: { listener_mode: 'h1_only', multiplex_ready: true },
    })
  })
})
