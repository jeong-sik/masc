import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  filterHotSessions,
  formatHitRate,
  formatAvgBufferedBytes,
  shouldRefreshFromEvent,
  formatLatencyFromSeconds,
  formatFloat,
  formatIdle,
  compactId,
  statusDot,
  toneTextClass,
  queuePressureTone,
  sseTone,
  transportTone,
  grpcTone,
  websocketTone,
  webrtcActive,
  webrtcTone,
  http2Tone,
  staleTone,
  agentPoolTone,
  formatMetricValue,
  transportTruthLine,
  transportEyebrow,
  webrtcEyebrow,
  type StatusTone,
} from './transport-health'
import type { HotSession, TransportHealthData } from '../api/transport-health'
import type { SSEEvent } from '../types'

function sampleResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    summary: {
      primary_path: 'streamable_http',
      queue_pressure: 'steady',
      recent_messages: null,
      recent_messages_available: false,
      recent_messages_source: 'metrics_only',
      external_fanout_targets: 0,
    },
    sse: {
      sessions_observer: 1,
      sessions_agent_stream: 0,
      sessions_presence: 0,
      sessions_total: 1,
      external_subscribers: 0,
      broadcast_avg_seconds: 0.01,
      broadcast_count: 2,
      queue_avg_depth: 0,
      queue_max_depth: 1,
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
      enabled: true,
      configured: true,
      listening: true,
      port: 50052,
      active_streams: 0,
      subscribers: 0,
      heartbeat_avg_seconds: 0,
      events_delivered: 0,
      events_dropped: 0,
    },
    websocket: {
      enabled: true,
      configured: true,
      listening: true,
      mode: 'standalone',
      port: 8936,
      sessions: 0,
      relay_source: 'sse_external_subscriber',
      delivery: {
        parse_cache_hits: 0,
        parse_cache_misses: 0,
        bytes_cache_hits: 0,
        bytes_cache_misses: 0,
        client_acks: 0,
        throttled_deliveries: 0,
        client_buffered_bytes_sum: 0,
        client_buffered_bytes_count: 0,
      },
    },
    webrtc: {
      enabled: true,
      configured: true,
      signaling_available: true,
      signaling_mode: 'shared_http',
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
      default_transport: 'streamable_http',
      supports_post: true,
      supports_sse_upgrade: true,
      supports_delete: true,
    },
    http2: {
      listener_mode: 'h2',
      multiplex_ready: true,
      prior_knowledge_path: '/mcp',
    },
    cluster: {
      cluster: 'default',
      workspace_id: 'default',
      topology_available: false,
      topology_source: 'metrics_only',
      total_units: null,
      managed_units: null,
      live_agents: null,
      active_operations: null,
      stale_units: null,
    },
    agent_health: {
      stale_total: 0,
      lifecycle_dispatch_rejections_total: 0,
    },
    generated_at: '2026-04-02T00:00:00Z',
    ...overrides,
  }
}

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadComponentWithApi(api: {
  fetchTransportHealth: () => Promise<unknown>
  lastEvent: { value: unknown }
}) {
  vi.resetModules()
  vi.doMock('../api/transport-health', () => ({
    fetchTransportHealth: api.fetchTransportHealth,
    decodeTransportHealthData: (payload: unknown) => payload,
  }))
  vi.doMock('../sse', () => ({
    lastEvent: api.lastEvent,
  }))
  const module = await import('./transport-health')
  module.resetTransportHealthState()
  return module
}

describe('TransportHealthPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(async () => {
    const { resetTransportHealthState } = await import('./transport-health')
    resetTransportHealthState()
    render(null, container)
    container.remove()
    vi.useRealTimers()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/transport-health')
    vi.doUnmock('../sse')
  })

  it('renders WebRTC signaling truth without pretending there is a separate listener', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        webrtc: {
          enabled: true,
          configured: true,
          signaling_available: false,
          signaling_mode: 'shared_http',
          pending_offers: 0,
          active_peers: 0,
          live_connections: 0,
          connected_channels: 0,
          ice_server_count: 2,
        },
      }),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-monitoring-surface')).not.toBeNull()
    expect(fetchTransportHealth).toHaveBeenCalled()
    expect(container.textContent).toContain('WebRTC')
    expect(container.textContent).toContain('시그널링')
    expect(container.textContent).toContain('shared_http')
    expect(container.innerHTML).toContain('시그널링 중단')
    expect(container.innerHTML).not.toContain('2 ICE')
    expect(container.textContent).toContain('namespace default')
    expect(container.textContent).toContain('프레즌스 스트림')
    expect(container.textContent).toContain('/events/presence')
  })

  it('renders namespace chip with cluster prefix for non-default clusters', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        cluster: {
          cluster: 'prod',
          workspace_id: 'default',
          topology_available: false,
          topology_source: 'metrics_only',
          total_units: null,
          managed_units: null,
          live_agents: null,
          active_operations: null,
          stale_units: null,
        },
      }),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(fetchTransportHealth).toHaveBeenCalled()
    expect(container.textContent).toContain('prod / namespace default')
  })

  it('renders live-vs-cache truth line when projection diagnostics exist', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        projection_diagnostics: {
          source: 'live_metrics',
          cache_state: 'fresh',
          last_success_at: '2026-04-15T10:00:00Z',
          last_attempt_at: '2026-04-15T10:00:01Z',
          last_error_at: null,
          stale_reason: null,
          stale_age_ms: null,
        },
      }),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('live_metrics')
    expect(container.textContent).toContain('cache fresh')
    expect(container.textContent).toContain('last ok 2026-04-15T10:00:00Z')
  })

  it('renders relay health rows and lifecycle rejects when boundary failures are present', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        summary: {
          primary_path: 'streamable_http',
          queue_pressure: 'high',
          recent_messages: null,
          recent_messages_available: false,
          recent_messages_source: 'metrics_only',
          external_fanout_targets: 0,
        },
        sse: {
          sessions_observer: 1,
          sessions_agent_stream: 0,
          sessions_presence: 1,
          sessions_total: 2,
          external_subscribers: 0,
          broadcast_avg_seconds: 0.01,
          broadcast_count: 2,
          queue_avg_depth: 0,
          queue_max_depth: 1,
          relay_queue_depth: 3,
          relay_retry_total: 4,
          relay_retry_append: 1,
          relay_retry_broadcast: 3,
          relay_drop_total: 2,
          relay_drop_queue: 1,
          relay_drop_append: 1,
          relay_drop_broadcast: 0,
          hot_sessions: [],
        },
        agent_health: {
          stale_total: 0,
          lifecycle_dispatch_rejections_total: 5,
        },
      }),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('high')
    expect(container.textContent).toContain('릴레이 큐')
    expect(container.textContent).toContain('릴레이 재시도')
    expect(container.textContent).toContain('릴레이 드롭')
    expect(container.textContent).toContain('라이프사이클 거부')
    expect(container.textContent).toContain('append 1 · broadcast 3')
    expect(container.textContent).toContain('queue 1 · append 1 · broadcast 0')
  })

  it('renders gRPC events_dropped row and flags buffer saturation when non-zero', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        grpc: {
          enabled: true,
          configured: true,
          listening: true,
          port: 50052,
          active_streams: 1,
          subscribers: 1,
          heartbeat_avg_seconds: 0,
          events_delivered: 100,
          events_dropped: 7,
        },
      }),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(fetchTransportHealth).toHaveBeenCalled()
    expect(container.textContent).toContain('드롭된 이벤트')
    expect(container.textContent).toContain('7')
    // The '서킷 오픈' counterpart on the WebSocket card is '버퍼 포화'
    // on gRPC — both variants convey "capacity pressure, attention
    // required" without using the same word for different paths.
    expect(container.textContent).toContain('버퍼 포화')
  })

  it('renders gRPC events_dropped with 정상 sub when no drops have happened', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse(),
    )

    const { TransportHealthPanel } = await loadComponentWithApi({
      fetchTransportHealth,
      lastEvent: signal(null),
    })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('드롭된 이벤트')
    expect(container.textContent).toContain('정상')
    expect(container.textContent).not.toContain('버퍼 포화')
  })

  it('debounces SSE-driven transport refreshes through FetchScheduler', async () => {
    const lastEvent = signal<unknown>(null)
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleResponse())

    const { TransportHealthPanel } = await loadComponentWithApi({ fetchTransportHealth, lastEvent })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()
    expect(fetchTransportHealth).toHaveBeenCalledTimes(1)

    vi.useFakeTimers()
    lastEvent.value = { type: 'agent_bound' }
    lastEvent.value = { type: 'agent_unbound' }
    lastEvent.value = { type: 'task_claimed' }
    await vi.advanceTimersByTimeAsync(1_199)
    expect(fetchTransportHealth).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(1)
    expect(fetchTransportHealth).toHaveBeenCalledTimes(2)
  })
})

describe('filterHotSessions', () => {
  const sessions: HotSession[] = [
    { session_id: 'aaaa1111-2222-3333-4444-555566667777', kind: 'observer', queue_depth: 5, last_event_id: 101, idle_seconds: 3 },
    { session_id: 'bbbb9999-8888-7777-6666-555544443333', kind: 'agent_stream', queue_depth: 12, last_event_id: 202, idle_seconds: 9 },
    { session_id: 'cccc0000-1111-2222-3333-444455556666', kind: 'external', queue_depth: 3, last_event_id: 303, idle_seconds: 30 },
  ]

  it('returns the input reference unchanged when query is empty', () => {
    const result = filterHotSessions(sessions, '')
    expect(result).toBe(sessions)
  })

  it('returns the input reference unchanged when query is whitespace-only', () => {
    const result = filterHotSessions(sessions, '   \t ')
    expect(result).toBe(sessions)
  })

  it('matches substring of session_id (full uuid, beyond compact visual)', () => {
    // '8888' only appears in the MIDDLE of bbbb's full uuid (compactId would hide it).
    const result = filterHotSessions(sessions, '8888')
    expect(result).toHaveLength(1)
    expect(result[0]!.session_id).toBe('bbbb9999-8888-7777-6666-555544443333')
  })

  it('matches substring of kind', () => {
    const result = filterHotSessions(sessions, 'agent')
    expect(result).toHaveLength(1)
    expect(result[0]!.kind).toBe('agent_stream')
  })

  it('matches last_event_id by numeric-string substring', () => {
    const result = filterHotSessions(sessions, '303')
    expect(result).toHaveLength(1)
    expect(result[0]!.last_event_id).toBe(303)
  })

  it('is case-insensitive', () => {
    const upper = filterHotSessions(sessions, 'OBSERVER')
    const lower = filterHotSessions(sessions, 'observer')
    expect(upper).toHaveLength(1)
    expect(lower).toHaveLength(1)
    expect(upper[0]!.kind).toBe('observer')
  })

  it('trims the query before matching', () => {
    const result = filterHotSessions(sessions, '  agent_stream  ')
    expect(result).toHaveLength(1)
    expect(result[0]!.kind).toBe('agent_stream')
  })

  it('returns an empty array when nothing matches', () => {
    const result = filterHotSessions(sessions, 'zzz-not-present')
    expect(result).toEqual([])
  })

  it('does NOT match queue_depth (numeric field is intentionally excluded)', () => {
    // queue_depth 12 exists on bbbb session. Searching "12" should not match it
    // unless another field (session_id / kind / last_event_id) contains "12".
    // None of the fixture sessions have "12" in id/kind/last_event_id.
    const result = filterHotSessions(sessions, '12')
    expect(result).toEqual([])
  })
})

describe('formatHitRate', () => {
  it('returns em dash when the cache has not seen any traffic', () => {
    // An idle cache must read as "nothing happened", not "0% success" —
    // operators should not be alarmed by a fresh server.
    expect(formatHitRate(0, 0)).toBe('—')
  })

  it('computes a whole-number percentage', () => {
    expect(formatHitRate(90, 10)).toBe('90%')
    expect(formatHitRate(1, 3)).toBe('25%')
  })

  it('returns 100% when every observation is a hit', () => {
    expect(formatHitRate(50, 0)).toBe('100%')
  })

  it('returns 0% when every observation is a miss', () => {
    // Different from the idle case: misses-only means the cache exists
    // but its key never matched.  That IS a 0% reading.
    expect(formatHitRate(0, 5)).toBe('0%')
  })
})

describe('formatAvgBufferedBytes', () => {
  it('returns em dash when no ack has been observed', () => {
    expect(formatAvgBufferedBytes(0, 0)).toBe('—')
  })

  it('formats sub-kilobyte averages in bytes', () => {
    expect(formatAvgBufferedBytes(500, 1)).toBe('500 B')
  })

  it('switches to kilobytes above 1024 bytes', () => {
    // 10 acks totalling 20 KiB worth of buffered_amount → 2 KB avg.
    expect(formatAvgBufferedBytes(20 * 1024, 10)).toBe('2.0 KB')
  })

  it('switches to megabytes above a mebibyte', () => {
    // One ack reporting 4 MiB of buffered bytes.
    expect(formatAvgBufferedBytes(4 * 1024 * 1024, 1)).toBe('4.00 MB')
  })

  it('rounds byte averages to the nearest integer', () => {
    expect(formatAvgBufferedBytes(7, 2)).toBe('4 B')
  })
})

describe('shouldRefreshFromEvent', () => {
  it.each([
    [{ type: '' }, false],
    [{ type: 'keeper_heartbeat' }, false],
    [{ type: 'broadcast' }, true],
    [{ type: 'masc/broadcast' }, true],
    [{ type: 'agent_bound' }, true],
    [{ type: 'masc/agent_bound' }, true],
    [{ type: 'agent_unbound' }, true],
    [{ type: 'masc/agent_unbound' }, true],
    [{ type: 'task_claimed' }, true],
    [{ type: 'masc/task_started' }, true],
    [{ type: 'keeper_state_changed' }, true],
    [{ type: 'masc/keeper_offline' }, true],
    [{ type: 'decision_created' }, true],
    [{ type: 'runtime_param_changed' }, true],
    [{ type: 'client_input_received' }, true],
    [{ type: 'unknown_type' }, false],
  ] as const)('shouldRefreshFromEvent(%o) → %s', (event, expected) => {
    expect(shouldRefreshFromEvent(event as SSEEvent)).toBe(expected)
  })
})

describe('formatLatencyFromSeconds', () => {
  it.each([
    [0, '-'],
    [0.0000005, '1us'],
    [0.0005, '500us'],
    [0.5, '500.0ms'],
    [1.234, '1.23s'],
    [60, '60.00s'],
  ] as const)('formatLatencyFromSeconds(%s) → %s', (input, expected) => {
    expect(formatLatencyFromSeconds(input)).toBe(expected)
  })
})

describe('formatFloat', () => {
  it.each([
    [0, '0'],
    [0.123, '0.12'],
    [0.999, '1.00'],
    [1.5, '1.5'],
    [10.25, '10.3'],
    [100, '100.0'],
  ] as const)('formatFloat(%s) → %s', (input, expected) => {
    expect(formatFloat(input)).toBe(expected)
  })
})

describe('formatIdle', () => {
  it.each([
    [0, '0s'],
    [45, '45s'],
    [59, '59s'],
    [60, '1m'],
    [3599, '60m'],
    [3600, '1h'],
    [7200, '2h'],
  ] as const)('formatIdle(%s) → %s', (input, expected) => {
    expect(formatIdle(input)).toBe(expected)
  })
})

describe('compactId', () => {
  it.each([
    ['short', 'short'],
    ['exactly18charslong', 'exactly18charslong'],
    ['abcdefghijklmnopqrstuvwxyz', 'abcdefgh...uvwxyz'],
    ['aaaa1111-2222-3333-4444-555566667777', 'aaaa1111...667777'],
  ] as const)('compactId(%s) → %s', (input, expected) => {
    expect(compactId(input)).toBe(expected)
  })
})

describe('statusDot', () => {
  it.each([
    ['ok', 'bg-[var(--color-status-ok)]'],
    ['warn', 'bg-[var(--color-status-warn)]'],
    ['bad', 'bg-[var(--color-status-err)]'],
  ] as const)('statusDot(%s) → %s', (input, expected) => {
    expect(statusDot(input as StatusTone)).toBe(expected)
  })
})

describe('toneTextClass', () => {
  it.each([
    ['ok', 'text-[var(--color-status-ok)]'],
    ['warn', 'text-[var(--color-status-warn)]'],
    ['bad', 'text-[var(--color-status-err)]'],
  ] as const)('toneTextClass(%s) → %s', (input, expected) => {
    expect(toneTextClass(input as StatusTone)).toBe(expected)
  })
})

describe('queuePressureTone', () => {
  it.each([
    ['high', 'bad'],
    ['watch', 'warn'],
    ['steady', 'ok'],
    ['low', 'ok'],
    ['', 'ok'],
  ] as const)('queuePressureTone(%s) → %s', (input, expected) => {
    expect(queuePressureTone(input)).toBe(expected as StatusTone)
  })
})

describe('transportTone', () => {
  it.each([
    [false, true, true, 'warn'],
    [true, false, true, 'bad'],
    [true, true, true, 'ok'],
    [true, true, false, 'warn'],
    [false, false, false, 'warn'],
  ] as const)('transportTone(%s,%s,%s) → %s', (configured, listening, active, expected) => {
    expect(transportTone(configured, listening, active)).toBe(expected as StatusTone)
  })
})

describe('staleTone', () => {
  it.each([
    [0, 'ok'],
    [1, 'warn'],
    [2, 'warn'],
    [3, 'bad'],
    [10, 'bad'],
  ] as const)('staleTone(%s) → %s', (input, expected) => {
    expect(staleTone(input)).toBe(expected as StatusTone)
  })
})

describe('formatMetricValue', () => {
  it.each([
    [null, 'n/a'],
    [0, 0],
    [42, 42],
    [-1, -1],
  ] as const)('formatMetricValue(%s) → %s', (input, expected) => {
    expect(formatMetricValue(input)).toBe(expected)
  })
})

describe('transportEyebrow', () => {
  it.each([
    [false, true, 50052, '비활성'],
    [true, true, 50052, ':50052 활성'],
    [true, false, 50052, ':50052 중단'],
  ] as const)('transportEyebrow(%s,%s,%s) → %s', (configured, listening, port, expected) => {
    expect(transportEyebrow(configured, listening, port)).toBe(expected)
  })
})

function makeData(overrides?: Partial<TransportHealthData>): TransportHealthData {
  return {
    summary: {
      primary_path: 'streamable_http',
      queue_pressure: 'steady',
      recent_messages: null,
      recent_messages_available: false,
      recent_messages_source: 'metrics_only',
      external_fanout_targets: 0,
    },
    sse: {
      sessions_observer: 1,
      sessions_agent_stream: 0,
      sessions_presence: 0,
      sessions_total: 1,
      external_subscribers: 0,
      broadcast_avg_seconds: 0.01,
      broadcast_count: 2,
      queue_avg_depth: 0,
      queue_max_depth: 1,
      relay_queue_depth: 0,
      relay_retry_total: 0,
      relay_retry_append: 0,
      relay_retry_broadcast: 0,
      relay_drop_total: 0,
      relay_drop_append: 0,
      relay_drop_broadcast: 0,
      hot_sessions: [],
    },
    grpc: {
      enabled: true,
      configured: true,
      listening: true,
      port: 50052,
      active_streams: 0,
      subscribers: 0,
      heartbeat_avg_seconds: 0,
      events_delivered: 0,
      events_dropped: 0,
    },
    websocket: {
      enabled: true,
      configured: true,
      listening: true,
      mode: 'standalone',
      port: 8936,
      sessions: 0,
      relay_source: 'sse_external_subscriber',
      delivery: {
        parse_cache_hits: 0,
        parse_cache_misses: 0,
        bytes_cache_hits: 0,
        bytes_cache_misses: 0,
        client_acks: 0,
        throttled_deliveries: 0,
        client_buffered_bytes_sum: 0,
        client_buffered_bytes_count: 0,
      },
    },
    webrtc: {
      enabled: true,
      configured: true,
      signaling_available: true,
      signaling_mode: 'shared_http',
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
      default_transport: 'streamable_http',
      supports_post: true,
      supports_sse_upgrade: true,
      supports_delete: true,
    },
    http2: {
      listener_mode: 'h2',
      multiplex_ready: true,
      prior_knowledge_path: '/mcp',
    },
    cluster: {
      cluster: 'default',
      workspace_id: 'default',
      topology_available: false,
      topology_source: 'metrics_only',
      total_units: null,
      managed_units: null,
      live_agents: null,
      active_operations: null,
      stale_units: null,
    },
    agent_health: {
      stale_total: 0,
      lifecycle_dispatch_rejections_total: 0,
    },
    generated_at: '2026-04-02T00:00:00Z',
    ...overrides,
  } as unknown as TransportHealthData
}

describe('sseTone', () => {
  it('is bad when drops exist', () => {
    expect(sseTone(makeData({ sse: { ...makeData().sse, relay_drop_total: 1 } }))).toBe('bad')
  })
  it('is warn when retries or queue depth exist', () => {
    expect(sseTone(makeData({ sse: { ...makeData().sse, relay_retry_total: 1 } }))).toBe('warn')
    expect(sseTone(makeData({ sse: { ...makeData().sse, relay_queue_depth: 2 } }))).toBe('warn')
  })
  it('falls back to queue pressure tone when no relay issues', () => {
    expect(sseTone(makeData({ summary: { ...makeData().summary, queue_pressure: 'high' } }))).toBe('bad')
    expect(sseTone(makeData({ summary: { ...makeData().summary, queue_pressure: 'watch' } }))).toBe('warn')
    expect(sseTone(makeData())).toBe('ok')
  })
})

describe('grpcTone', () => {
  it('is ok when listening with active streams', () => {
    expect(grpcTone(makeData({ grpc: { ...makeData().grpc, active_streams: 1, subscribers: 1 } }))).toBe('ok')
  })
  it('degrades to warn when events are dropped on healthy base', () => {
    expect(grpcTone(makeData({ grpc: { ...makeData().grpc, active_streams: 1, subscribers: 1, events_dropped: 3 } }))).toBe('warn')
  })
  it('stays bad when listener is down regardless of drops', () => {
    expect(grpcTone(makeData({ grpc: { ...makeData().grpc, listening: false } }))).toBe('bad')
  })
  it('is warn when listening but no activity', () => {
    expect(grpcTone(makeData())).toBe('warn')
  })
})

describe('websocketTone', () => {
  it('is ok when listening with sessions', () => {
    expect(websocketTone(makeData({ websocket: { ...makeData().websocket, sessions: 2 } }))).toBe('ok')
  })
  it('degrades to warn when throttled on healthy base', () => {
    expect(websocketTone(makeData({ websocket: { ...makeData().websocket, sessions: 2, delivery: { ...makeData().websocket.delivery, throttled_deliveries: 1 } } }))).toBe('warn')
  })
  it('stays bad when listener is down', () => {
    expect(websocketTone(makeData({ websocket: { ...makeData().websocket, listening: false } }))).toBe('bad')
  })
  it('is warn when listening but no sessions', () => {
    expect(websocketTone(makeData())).toBe('warn')
  })
})

describe('webrtcActive', () => {
  it('returns false when all counts are zero', () => {
    expect(webrtcActive(makeData())).toBe(false)
  })
  it('returns true when any count is positive', () => {
    expect(webrtcActive(makeData({ webrtc: { ...makeData().webrtc, connected_channels: 1 } }))).toBe(true)
    expect(webrtcActive(makeData({ webrtc: { ...makeData().webrtc, live_connections: 1 } }))).toBe(true)
    expect(webrtcActive(makeData({ webrtc: { ...makeData().webrtc, active_peers: 1 } }))).toBe(true)
  })
})

describe('webrtcTone', () => {
  it('is ok when signaling is available and active', () => {
    expect(webrtcTone(makeData({ webrtc: { ...makeData().webrtc, connected_channels: 1 } }))).toBe('ok')
  })
  it('is bad when signaling is unavailable', () => {
    expect(webrtcTone(makeData({ webrtc: { ...makeData().webrtc, signaling_available: false } }))).toBe('bad')
  })
  it('is warn when signaling available but inactive', () => {
    expect(webrtcTone(makeData())).toBe('warn')
  })
})

describe('http2Tone', () => {
  it('is ok when multiplex_ready', () => {
    expect(http2Tone(makeData())).toBe('ok')
  })
  it('is warn when not multiplex_ready', () => {
    expect(http2Tone(makeData({ http2: { ...makeData().http2, multiplex_ready: false } }))).toBe('warn')
  })
})

describe('agentPoolTone', () => {
  it('is ok when everything is clean', () => {
    expect(agentPoolTone(makeData())).toBe('ok')
  })
  it('is warn when lifecycle rejects exist', () => {
    expect(agentPoolTone(makeData({ agent_health: { ...makeData().agent_health, lifecycle_dispatch_rejections_total: 3 } }))).toBe('warn')
  })
  it('is warn when stale agents are below threshold', () => {
    expect(agentPoolTone(makeData({ agent_health: { ...makeData().agent_health, stale_total: 1 } }))).toBe('warn')
  })
  it('is bad when stale agents reach threshold', () => {
    expect(agentPoolTone(makeData({ agent_health: { ...makeData().agent_health, stale_total: 5 } }))).toBe('bad')
  })
})

describe('transportTruthLine', () => {
  it('returns null when no projection_diagnostics', () => {
    expect(transportTruthLine(makeData())).toBeNull()
  })
  it('builds a line from source, cache state, and last success', () => {
    const data = makeData({
      projection_diagnostics: {
        source: 'live_metrics',
        cache_state: 'fresh',
        last_success_at: '2026-04-15T10:00:00Z',
        last_attempt_at: '2026-04-15T10:00:01Z',
        last_error_at: null,
        stale_reason: null,
        stale_age_ms: null,
      },
    })
    expect(transportTruthLine(data)).toBe('live_metrics · cache fresh · last ok 2026-04-15T10:00:00Z')
  })
  it('shows stale age when present instead of last success', () => {
    const data = makeData({
      projection_diagnostics: {
        source: 'live_metrics',
        cache_state: 'stale',
        last_success_at: '2026-04-15T10:00:00Z',
        last_attempt_at: '2026-04-15T10:00:01Z',
        last_error_at: null,
        stale_reason: null,
        stale_age_ms: 1234,
      },
    })
    expect(transportTruthLine(data)).toBe('live_metrics · cache stale · stale 1234ms')
  })
})

describe('webrtcEyebrow', () => {
  it('returns 비활성 when not configured', () => {
    expect(webrtcEyebrow(makeData({ webrtc: { ...makeData().webrtc, configured: false } }))).toBe('비활성')
  })
  it('returns signaling ready when available', () => {
    expect(webrtcEyebrow(makeData())).toBe('2 ICE · 시그널링 준비')
  })
  it('returns signaling down when unavailable', () => {
    expect(webrtcEyebrow(makeData({ webrtc: { ...makeData().webrtc, signaling_available: false } }))).toBe('시그널링 중단')
  })
})
