import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { filterHotSessions, formatHitRate, formatAvgBufferedBytes } from './transport-health'
import type { HotSession } from '../api/transport-health'

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
      sessions_coordinator: 0,
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
      listener_mode: 'h2',
      multiplex_ready: true,
      prior_knowledge_path: '/mcp',
    },
    cluster: {
      cluster: 'default',
      room_id: 'default',
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

    expect(fetchTransportHealth).toHaveBeenCalled()
    expect(container.textContent).toContain('WebRTC')
    expect(container.textContent).toContain('시그널링')
    expect(container.textContent).toContain('shared_http')
    expect(container.innerHTML).toContain('signaling down')
    expect(container.innerHTML).not.toContain('2 ICE')
    expect(container.textContent).toContain('namespace default')
  })

  it('renders namespace chip with cluster prefix for non-default clusters', async () => {
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(
      sampleResponse({
        cluster: {
          cluster: 'prod',
          room_id: 'default',
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
          sessions_coordinator: 0,
          sessions_total: 1,
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
    expect(container.textContent).toContain('Relay Queue')
    expect(container.textContent).toContain('Relay Retries')
    expect(container.textContent).toContain('Relay Drops')
    expect(container.textContent).toContain('Lifecycle Rejects')
    expect(container.textContent).toContain('append 1 · broadcast 3')
    expect(container.textContent).toContain('queue 1 · append 1 · broadcast 0')
  })

  it('debounces SSE-driven transport refreshes through FetchScheduler', async () => {
    const lastEvent = signal<unknown>(null)
    const fetchTransportHealth = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleResponse())

    const { TransportHealthPanel } = await loadComponentWithApi({ fetchTransportHealth, lastEvent })

    render(html`<${TransportHealthPanel} />`, container)
    await flushUi()
    expect(fetchTransportHealth).toHaveBeenCalledTimes(1)

    vi.useFakeTimers()
    lastEvent.value = { type: 'agent_joined' }
    lastEvent.value = { type: 'agent_left' }
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
    { session_id: 'bbbb9999-8888-7777-6666-555544443333', kind: 'coordinator', queue_depth: 12, last_event_id: 202, idle_seconds: 9 },
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
    const result = filterHotSessions(sessions, 'coord')
    expect(result).toHaveLength(1)
    expect(result[0]!.kind).toBe('coordinator')
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
    const result = filterHotSessions(sessions, '  coordinator  ')
    expect(result).toHaveLength(1)
    expect(result[0]!.kind).toBe('coordinator')
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
