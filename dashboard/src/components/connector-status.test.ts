import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

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

function sampleLiveResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    available: true,
    connected: true,
    stale: false,
    stale_after_sec: 30,
    error: '',
    status_path: '/tmp/discord_status.json',
    binding_store_path: '/tmp/discord_bindings.json',
    audit_path: '/tmp/discord_binding_audit.jsonl',
    updated_at: '2026-04-03T00:00:00Z',
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
  get: (path: string) => Promise<unknown>
  post?: (path: string, body: unknown) => Promise<unknown>
  lastEvent: { value: unknown }
  showToast?: (message: string, type?: string) => void
}) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    get: api.get,
    post: api.post ?? vi.fn().mockResolvedValue({ ok: true }),
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
    vi.doUnmock('../sse')
    vi.doUnmock('./common/toast')
  })

  it('renders direct Discord runtime and gate-observed health together', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>().mockImplementation(async path => {
      if (path === '/api/v1/gate/status') return sampleGateResponse()
      if (path === '/api/v1/gate/discord/status') return sampleLiveResponse()
      if (path === '/api/v1/gate/keepers?limit=50&detailed=true') return sampleKeepersResponse()
      throw new Error(`unexpected path: ${path}`)
    })

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      get,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(get).toHaveBeenCalledWith('/api/v1/gate/status')
    expect(get).toHaveBeenCalledWith('/api/v1/gate/discord/status')
    expect(get).toHaveBeenCalledWith('/api/v1/gate/keepers?limit=50&detailed=true')
    expect(text).toContain('Connector Operations')
    expect(text).toContain('Discord Direct')
    expect(text).toContain('connected')
    expect(text).toContain('sangsu')
    expect(text).toContain('keeper dir 2')
    expect(text).toContain('keeper-luna-agent')
    expect(text).toContain('Observed room bindings')
    expect(text).toContain('Recent binding audit')
    expect(text).toContain('Recent gate events')
    expect(text).toContain('keeper_error')
    expect(text).toContain('/tmp/discord_status.json')
  })

  it('still renders direct runtime when gate metrics are unavailable', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>().mockImplementation(async path => {
      if (path === '/api/v1/gate/status') throw new Error('GET /api/v1/gate/status: 503 Service Unavailable')
      if (path === '/api/v1/gate/discord/status') return sampleLiveResponse({ connected: false, stale: true })
      if (path === '/api/v1/gate/keepers?limit=50&detailed=true') throw new Error('GET /api/v1/gate/keepers: 401 Unauthorized')
      throw new Error(`unexpected path: ${path}`)
    })

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      get,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()
    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''

    expect(text).toContain('Discord Direct')
    expect(text).toContain('stale')
    expect(text).toContain('Gate metrics unavailable')
    expect(text).toContain('Direct Discord runtime is visible')
    expect(text).toContain('keeper directory unavailable, manual entry only')
  })

  it('posts bind and unbind actions through the dashboard endpoints', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>().mockImplementation(async path => {
      if (path === '/api/v1/gate/status') return sampleGateResponse()
      if (path === '/api/v1/gate/discord/status') return sampleLiveResponse()
      if (path === '/api/v1/gate/keepers?limit=50&detailed=true') return sampleKeepersResponse()
      throw new Error(`unexpected path: ${path}`)
    })
    const post = vi.fn<(path: string, body: unknown) => Promise<unknown>>().mockResolvedValue({ ok: true })
    const showToast = vi.fn()

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      get,
      post,
      lastEvent: signal(null),
      showToast,
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const channelInput = container.querySelector('input[aria-label="Discord channel id"]') as HTMLInputElement | null
    const keeperInput = container.querySelector('input[aria-label="Keeper name"]') as HTMLInputElement | null
    expect(channelInput).not.toBeNull()
    expect(keeperInput).not.toBeNull()

    if (!channelInput || !keeperInput) {
      throw new Error('expected bind form inputs to exist')
    }

    channelInput.value = '999999'
    channelInput.dispatchEvent(new Event('input', { bubbles: true }))
    keeperInput.value = 'nova'
    keeperInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    const bindButton = Array.from(container.querySelectorAll('button'))
      .find(candidate => candidate.textContent?.trim() === 'Bind')
    bindButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(post).toHaveBeenCalledWith('/api/v1/gate/discord/bind', {
      channel_id: '999999',
      keeper_name: 'nova',
    })
    expect(showToast).toHaveBeenCalledWith('Bound 999999 -> nova', 'success')

    const unbindButton = Array.from(container.querySelectorAll('button'))
      .find(candidate => candidate.textContent?.trim() === 'Unbind')
    unbindButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(post).toHaveBeenCalledWith('/api/v1/gate/discord/unbind', {
      channel_id: '999999',
    })
    expect(showToast).toHaveBeenCalledWith('Unbound 999999', 'success')
  })

  it('shows selected keeper runtime metadata from the keeper directory', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>().mockImplementation(async path => {
      if (path === '/api/v1/gate/status') return sampleGateResponse()
      if (path === '/api/v1/gate/discord/status') return sampleLiveResponse()
      if (path === '/api/v1/gate/keepers?limit=50&detailed=true') return sampleKeepersResponse()
      throw new Error(`unexpected path: ${path}`)
    })

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      get,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const keeperSelect = container.querySelector('select') as HTMLSelectElement | null
    expect(keeperSelect).not.toBeNull()
    if (!keeperSelect) {
      throw new Error('expected keeper select to exist')
    }

    keeperSelect.value = 'nova'
    keeperSelect.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi()

    const text = container.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(text).toContain('status busy')
    expect(text).toContain('model gemini-2.5-flash')
    expect(text).toContain('runtime keeper-nova-agent')
  })
})
