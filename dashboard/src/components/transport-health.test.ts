import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

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
