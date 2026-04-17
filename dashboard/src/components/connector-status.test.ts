import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.setConfig({
  testTimeout: 40000,
  hookTimeout: 40000,
})

function sampleGateResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    channels: [
      {
        channel: 'discord',
        message_count: 12,
        success_count: 10,
        error_count: 2,
        duplicate_count: 1,
        validation_error_count: 0,
        keeper_error_count: 2,
        dispatch_unavailable_count: 0,
        internal_error_count: 0,
        last_activity: '2026-04-03T00:00:00Z',
        last_success: '2026-04-03T00:00:00Z',
        last_error_at: '2026-04-03T00:00:00Z',
        last_keeper: 'luna',
        last_room_id: '123456',
        last_error: 'upstream timeout',
        last_error_kind: 'keeper',
        last_outcome: 'keeper_error',
        avg_duration_ms: 1400,
        max_duration_ms: 4800,
        slow_count: 3,
        slow_rate_pct: 25,
        success_rate_pct: 91,
        room_count: 2,
        health: 'degraded',
      },
    ],
    bindings: [
      {
        channel: 'discord',
        room_id: '123456',
        keeper: 'luna',
        message_count: 8,
        success_count: 7,
        error_count: 1,
        duplicate_count: 0,
        last_activity: '2026-04-03T00:00:00Z',
        last_success: '2026-04-03T00:00:00Z',
        last_error_at: '2026-04-03T00:00:00Z',
        last_error: 'upstream timeout',
        last_error_kind: 'keeper',
        last_outcome: 'keeper_error',
        avg_duration_ms: 1400,
        max_duration_ms: 4800,
        success_rate_pct: 88,
        health: 'degraded',
      },
    ],
    recent_events: [
      {
        seq: 12,
        timestamp: '2026-04-03T00:00:00Z',
        channel: 'discord',
        room_id: '123456',
        keeper: 'luna',
        outcome: 'keeper_error',
        error_kind: 'keeper',
        error: 'upstream timeout',
        duration_ms: 4800,
      },
    ],
    total_messages: 12,
    total_success: 10,
    total_errors: 2,
    total_duplicates: 1,
    success_rate_pct: 91,
    dedup_table_size: 4,
    uptime_seconds: 3600,
    ...overrides,
  }
}

function sampleConnectorsResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    connectors: [
      {
        connector_id: 'discord',
        display_name: 'Discord',
        channel: 'discord',
        capabilities: ['runtime_status', 'bindings', 'audit'],
        status: 'connected',
        available: true,
        connected: true,
        stale: false,
        stale_after_sec: 30,
        error: '',
        status_path: '/tmp/discord_status.json',
        binding_store_path: '/tmp/discord_bindings.json',
        audit_path: '/tmp/discord_binding_audit.jsonl',
        updated_at: '2026-04-03T00:00:00Z',
        reply_mode: '',
        self_chat_guid: '',
        last_ready_at: '2026-04-03T00:00:00Z',
        bot_user_name: 'sangsu',
        bot_user_id: '1489985300729172039',
        guild_count: 2,
        gate_base_url: 'http://localhost:8935',
        gate_healthy: true,
        gate_health_checked_at: '2026-04-03T00:00:00Z',
        binding_source: 'persisted',
        runtime_bindings_count: 1,
        pid: 4242,
        configured_bindings: [
          {
            channel_id: '123456',
            keeper_name: 'luna',
          },
        ],
        recent_audit: [
          {
            timestamp: '2026-04-03T00:00:00Z',
            action: 'bind',
            guild_id: 'guild-1',
            channel_id: '123456',
            keeper_name: 'luna',
            actor_id: 'dashboard',
            actor_name: 'dashboard',
            previous_keeper: '',
          },
        ],
      },
    ],
    total: 1,
    active_count: 1,
    generated_at: '2026-04-03T00:00:00Z',
    ...overrides,
  }
}

function sampleKeepersResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    count: 2,
    keepers: [
      {
        name: 'luna',
        agent_name: 'keeper-luna-agent',
        status: 'idle',
        model: 'glm-5',
        keepalive_running: true,
      },
      {
        name: 'nova',
        agent_name: 'keeper-nova-agent',
        status: 'busy',
        model: 'gemini-2.5-flash',
        keepalive_running: true,
      },
    ],
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
  fetchGateStatus: () => Promise<unknown>
  fetchGateConnectors: () => Promise<unknown>
  fetchGateKeepers: () => Promise<unknown>
  post?: (path: string, body: unknown) => Promise<unknown>
  lastEvent: { value: unknown }
  showToast?: (message: string, type?: string) => void
}) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    post: api.post ?? vi.fn().mockResolvedValue({ ok: true }),
  }))
  vi.doMock('../api/gate', () => ({
    fetchGateStatus: api.fetchGateStatus,
    fetchGateConnectors: api.fetchGateConnectors,
    fetchGateKeepers: api.fetchGateKeepers,
  }))
  vi.doMock('../sse', () => ({
    lastEvent: api.lastEvent,
  }))
  vi.doMock('./common/toast', () => ({
    showToast: api.showToast ?? vi.fn(),
  }))
  const module = await import('./connector-status')
  module.resetConnectorStatusState()
  return module
}

describe('ConnectorStatusPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(async () => {
    const { resetConnectorStatusState } = await import('./connector-status')
    resetConnectorStatusState()
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/core')
    vi.doUnmock('../api/gate')
    vi.doUnmock('../sse')
    vi.doUnmock('./common/toast')
  })

  it('renders direct Discord runtime and gate-observed health together', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse())
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(fetchGateStatus).toHaveBeenCalled()
    expect(fetchGateConnectors).toHaveBeenCalled()
    expect(fetchGateKeepers).toHaveBeenCalled()
    // Heading copy is now Korean ("커넥터" + intro line). Asserting on the
    // intro substring keeps the test resilient to title tweaks.
    expect(text).toContain('4종 채널 sidecar')
    expect(text).toContain('connected')
    expect(text).toContain('Discord')
    expect(text).toContain('sangsu')
    expect(text).toContain('luna')
    expect(text).toContain('nova')
    expect(text).toContain('keeper-luna-agent')
    expect(text).toContain('Observed room bindings')
    expect(text).toContain('Recent gate events')
    expect(text).toContain('keeper_error')
    expect(text).toContain('/tmp/discord_status.json')
  })

  it('still renders direct runtime when gate metrics are unavailable', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockRejectedValue(new Error('GET /api/v1/gate/status: 503 Service Unavailable'))
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        connected: false,
        stale: true,
        status: 'stale',
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockRejectedValue(new Error('GET /api/v1/gate/keepers: 401 Unauthorized'))

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(text).toContain('Discord')
    expect(text).toContain('stale')
    expect(text).toContain('Gate metrics unavailable')
    expect(text).toContain('Gate-advertised connector runtime is visible')
    expect(text).toContain('keeper directory unavailable, manual entry only')
  })

  it('prefers backend-advertised connector status over derived booleans', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        available: true,
        connected: false,
        stale: false,
        status: 'connected',
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(text).toContain('connected')
    expect(text).not.toContain('disconnected')
  })

  it('renders iMessage reply mode metadata when advertised by the runtime', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        connector_id: 'imessage',
        display_name: 'iMessage',
        channel: 'imessage',
        reply_mode: 'self-chat',
        self_chat_guid: 'self-chat-guid',
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(text).toContain('reply self-chat')
    expect(text).toContain('self-chat self-chat-guid')
  })

  it('posts bind and unbind actions through the dashboard endpoints', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const initialState = sampleConnectorsResponse()
    const afterBindState = sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        configured_bindings: [
          { channel_id: '123456', keeper_name: 'luna' },
          { channel_id: '999999', keeper_name: 'nova' },
        ],
        runtime_bindings_count: 2,
      }],
    })
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>()
      .mockResolvedValueOnce(initialState)
      .mockResolvedValue(afterBindState)
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())
    const post = vi.fn<(path: string, body: unknown) => Promise<unknown>>().mockResolvedValue({ ok: true })
    const showToast = vi.fn()

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      post,
      lastEvent: signal(null),
      showToast,
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const addChannelButton = container.querySelector<HTMLButtonElement>('button[aria-label="add channel to nova"]')
    expect(addChannelButton).not.toBeNull()
    addChannelButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    const channelInput = container.querySelector<HTMLInputElement>('input[aria-label="Discord channel id"]')
    expect(channelInput).not.toBeNull()
    channelInput!.value = '999999'
    channelInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    const bindButton = Array.from(container.querySelectorAll('button'))
      .find(candidate => candidate.textContent?.trim() === 'bind')
    expect(bindButton).toBeDefined()
    bindButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(post).toHaveBeenCalledWith('/api/v1/gate/connector/bind?name=discord', {
      channel_id: '999999',
      keeper_name: 'nova',
    })
    expect(showToast).toHaveBeenCalledWith('Bound 999999 -> nova', 'success')

    const unbindButton = container.querySelector<HTMLButtonElement>('button[aria-label="unbind 999999"]')
    expect(unbindButton).not.toBeNull()
    unbindButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(post).toHaveBeenCalledWith('/api/v1/gate/connector/unbind?name=discord', {
      channel_id: '999999',
    })
    expect(showToast).toHaveBeenCalledWith('Unbound 999999', 'success')
  })

  it('renders one section per directory keeper (keeper-first grouping)', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse())
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const lunaGroup = container.querySelector('[data-keeper="luna"]')
    const novaGroup = container.querySelector('[data-keeper="nova"]')
    expect(lunaGroup).not.toBeNull()
    expect(novaGroup).not.toBeNull()
    expect(lunaGroup!.textContent).toContain('luna')
    expect(lunaGroup!.querySelector('[data-channel-id="123456"]')).not.toBeNull()
    expect(novaGroup!.textContent).toContain('(no channels)')
  })

  it('groups bindings for unknown keepers under a warning section', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        configured_bindings: [
          { channel_id: '123456', keeper_name: 'luna' },
          { channel_id: '999888', keeper_name: 'bob_keeper' },
        ],
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(text).toContain('⚠')
    expect(text).toContain('bob_keeper')
    expect(text).toContain('binding references undefined keeper')
    const bobGroup = container.querySelector('[data-keeper="bob_keeper"]')
    expect(bobGroup).not.toBeNull()
    expect(bobGroup!.querySelector('[data-channel-id="999888"]')).not.toBeNull()
  })

  it('shows sidecar-off empty state when no bindings and sidecar offline', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        available: false,
        connected: false,
        stale: false,
        status: 'offline',
        configured_bindings: [],
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(text).toContain('Sidecar not started')
    expect(text).toContain('cd sidecars/discord-bot && ./run.sh')
  })

  it('shows no-keepers empty state when keeper directory is empty', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        available: false,
        connected: false,
        status: 'offline',
        configured_bindings: [],
      }],
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue({ count: 0, keepers: [] })

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(text).toContain('No keepers configured')
  })

  it('expands [▾] header toggle to show per-dot liveness and metadata', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse())
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const beforeText = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(beforeText).not.toContain('Browser → Server')
    expect(beforeText).not.toContain('keeper dir 2')

    const toggleButton = container.querySelector<HTMLButtonElement>('button[aria-label="toggle header details"]')
    expect(toggleButton).not.toBeNull()
    toggleButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    const afterText = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(afterText).toContain('Browser → Server')
    expect(afterText).toContain('Server → Sidecar')
    expect(afterText).toContain('keeper dir 2')
  })

  it('shows keeper metadata in each group header', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse())
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const novaGroup = container.querySelector('[data-keeper="nova"]')
    expect(novaGroup).not.toBeNull()
    const novaText = novaGroup!.textContent ?? ''
    expect(novaText).toContain('status busy')
    expect(novaText).toContain('model gemini-2.5-flash')
    expect(novaText).toContain('runtime keeper-nova-agent')
  })
})
