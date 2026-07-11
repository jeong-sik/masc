import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// 90s window absorbs cold-build transform overhead (observed 60-140s on
// the first run) for the first/heaviest test in this file — render of a
// fully populated gate + connectors + keepers sample. Hot-cache runs
// finish in well under 1s, so the budget is effectively never reached in
// steady state. Raised from 60s after C21 added two new helper imports
// pushed the cold-transform path past the previous budget.
vi.setConfig({
  testTimeout: 90000,
  hookTimeout: 90000,
})

describe('connector mobile overflow contract', () => {
  it('keeps the wide audit table reachable through an internal horizontal scroller', () => {
    const css = readFileSync(resolve(__dirname, '../styles/connectors-v2.css'), 'utf8')
    const auditRule = css.match(/\.cn-audit\s*\{([^}]*)\}/)?.[1] ?? ''
    const tableRule = css.match(/\.cn-audit table\s*\{([^}]*)\}/)?.[1] ?? ''
    expect(auditRule).toContain('overflow-x: auto')
    expect(tableRule).toContain('min-width: 500px')
  })
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
        last_workspace_id: '123456',
        last_error: 'upstream timeout',
        last_error_kind: 'keeper',
        last_outcome: 'keeper_error',
        avg_duration_ms: 1400,
        max_duration_ms: 4800,
        slow_count: 3,
        slow_rate_pct: 25,
        success_rate_pct: 91,
        workspace_count: 2,
        health: 'degraded',
      },
    ],
    bindings: [
      {
        channel: 'discord',
        workspace_id: '123456',
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
        workspace_id: '123456',
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
        source_health: {
          storage_paths: 'fallback',
          runtime_summary: 'fallback',
          binding_summary: 'fallback',
          names: 'fallback',
          observed_channel: 'missing',
        },
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
        model: 'gemini-3-flash-preview',
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
    connected: { value: true },
    reconnectCount: { value: 0 },
    lastDisconnectedAt: { value: 0 },
  }))
  vi.doMock('./common/toast', () => ({
    showToast: api.showToast ?? vi.fn(),
  }))
  // The data-driven KPI strip is plain Preact, so the caller test exercises
  // its real implementation instead of substituting a framework shim.
  const module = await import('./connector-status')
  module.resetConnectorStatusState()
  return module
}

describe('ConnectorStatusPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = '#connectors?section=connector-status'
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
    expect(text).toContain('커넥터')
    expect(text).toContain('혼합 연결')
    expect(text).toContain('Discord는 서버 내장 gateway')
    expect(text).toContain('connected')
    expect(text).toContain('Discord')
    expect(text).toContain('sangsu')
    expect(text).toContain('luna')
    expect(text).toContain('nova')
    expect(text).toContain('keeper-luna-agent')
    expect(text).toContain('Observed workspace bindings')
    expect(text).toContain('Recent gate events')
    expect(text).toContain('keeper_error')
    expect(text).toContain('/tmp/discord_status.json')
  })

  it('renders a single selected-detail panel in the all-connectors view', async () => {
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

    const detailPanels = container.querySelectorAll('[data-testid="connector-detail-panel"]')
    expect(detailPanels.length).toBe(1)
    expect(detailPanels[0]?.textContent).toContain('Discord')
    const sourceHealth = detailPanels[0]?.querySelector('[data-testid="connector-source-health"]')
    expect(sourceHealth?.textContent).toContain('source health')
    expect(sourceHealth?.querySelector('[data-connector-source-health="storage_paths"]')?.getAttribute('data-connector-source-health-state')).toBe('fallback')
    expect(sourceHealth?.querySelector('[data-connector-source-health="observed_channel"]')?.getAttribute('data-connector-source-health-state')).toBe('missing')
    expect(container.querySelectorAll('button[aria-label="toggle header details"]').length).toBe(1)
  })

  it('switches the selected detail panel when an overview tile is clicked', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const discord = sampleConnectorsResponse().connectors[0]
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [
        discord,
        {
          ...discord,
          connector_id: 'imessage',
          display_name: 'iMessage',
          channel: 'imessage',
          status_path: '/tmp/imessage_status.json',
          binding_store_path: '/tmp/imessage_bindings.json',
          audit_path: '/tmp/imessage_binding_audit.jsonl',
          names_path: '/tmp/imessage_names.json',
          bot_user_name: 'Messages Bot',
          reply_mode: 'self-chat',
          self_chat_guid: 'self-chat-guid',
          configured_bindings: [{ channel_id: 'imsg-workspace', keeper_name: 'nova' }],
          recent_audit: [],
        },
      ],
      total: 2,
      active_count: 2,
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

    const detailPanel = container.querySelector('[data-testid="connector-detail-panel"]') as HTMLElement | null
    expect(detailPanel).not.toBeNull()
    expect(detailPanel!.textContent).toContain('Discord')

    const imessageButton = container.querySelector<HTMLButtonElement>('button[aria-label="iMessage 상세 보기"]')
    expect(imessageButton).not.toBeNull()
    imessageButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(detailPanel!.textContent).toContain('iMessage')
    expect(detailPanel!.textContent).toContain('reply self-chat')
    expect(detailPanel!.textContent).toContain('self-chat self-chat-guid')
  })

  it('routes connector sub-states through the route switcher', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const discord = sampleConnectorsResponse().connectors[0]
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [
        discord,
        {
          ...discord,
          connector_id: 'imessage',
          display_name: 'iMessage',
          channel: 'imessage',
          status_path: '/tmp/imessage_status.json',
          binding_store_path: '/tmp/imessage_bindings.json',
          audit_path: '/tmp/imessage_binding_audit.jsonl',
          names_path: '/tmp/imessage_names.json',
          bot_user_name: 'Messages Bot',
          reply_mode: 'self-chat',
          self_chat_guid: 'self-chat-guid',
          configured_bindings: [{ channel_id: 'imsg-workspace', keeper_name: 'nova' }],
          recent_audit: [],
        },
      ],
      total: 2,
      active_count: 2,
    }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    window.location.hash = '#connectors?section=connector-status&connector=imessage'
    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="connector-route-switcher"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="connector-route-imessage"]')?.getAttribute('data-active')).toBe('true')
    expect(container.querySelector('[data-testid="connector-route-all"]')?.getAttribute('data-active')).toBe('false')
    expect(container.querySelector('[data-testid="connector-gate-grid"]')).toBeNull()
    expect(container.textContent).toContain('iMessage')
    expect(container.textContent).toContain('reply self-chat')

    const allButton = container.querySelector<HTMLButtonElement>('[data-testid="connector-route-all"]')
    expect(allButton).not.toBeNull()
    allButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(window.location.hash).toBe('#connectors?section=connector-status')
    expect(container.querySelector('[data-testid="connector-route-all"]')?.getAttribute('data-active')).toBe('true')
    expect(container.querySelector('[data-testid="connector-gate-grid"]')).not.toBeNull()

    const telegramButton = container.querySelector<HTMLButtonElement>('[data-testid="connector-route-telegram"]')
    expect(telegramButton).not.toBeNull()
    telegramButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(window.location.hash).toBe('#connectors?section=connector-status&connector=telegram')
    expect(container.querySelector('[data-testid="connector-route-telegram"]')?.getAttribute('data-active')).toBe('true')
    expect(container.querySelector('[data-testid="connector-gate-grid"]')).toBeNull()
    expect(container.textContent).toContain('Telegram')
  })

  it('preserves header expansion state per connector when switching selected detail', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const discord = sampleConnectorsResponse().connectors[0]
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [
        discord,
        {
          ...discord,
          connector_id: 'imessage',
          display_name: 'iMessage',
          channel: 'imessage',
          status_path: '/tmp/imessage_status.json',
          binding_store_path: '/tmp/imessage_bindings.json',
          audit_path: '/tmp/imessage_binding_audit.jsonl',
          names_path: '/tmp/imessage_names.json',
          configured_bindings: [{ channel_id: 'imsg-workspace', keeper_name: 'nova' }],
          recent_audit: [],
        },
      ],
      total: 2,
      active_count: 2,
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

    const toggleButton = container.querySelector<HTMLButtonElement>('button[aria-label="toggle header details"]')
    expect(toggleButton).not.toBeNull()
    toggleButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()
    expect(container.textContent).toContain('Browser → Server')

    const imessageButton = container.querySelector<HTMLButtonElement>('button[aria-label="iMessage 상세 보기"]')
    expect(imessageButton).not.toBeNull()
    imessageButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()
    expect(container.textContent ?? '').not.toContain('Browser → Server')

    const discordButton = container.querySelector<HTMLButtonElement>('button[aria-label="Discord 상세 보기"]')
    expect(discordButton).not.toBeNull()
    discordButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()
    expect(container.textContent).toContain('Browser → Server')
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
    expect(text).toContain('메트릭 없음')
    expect(text).toContain('connector runtime은 등록됐으나 게이트가 관찰한 트래픽은 아직 없습니다')
    expect(text).toContain('keeper 디렉토리 사용 불가, 수동 입력만 가능')
    expect(text).toContain('Next: 지금은 수동 입력으로 진행')
    expect(text).toContain('config/keepers/')
    expect(text).toContain('/api/v1/gate/keepers')

    // Directory-error panel uses informational amber + left stripe so
    // operators don't read the accent-gradient-tinted neutral
    // background as success. Mirrors the "Sidecar not started" panel
    // treatment from #8038 for cross-panel consistency.
    const dirPanel = container.querySelector('[data-keeper-directory-error-panel]') as HTMLElement | null
    expect(dirPanel).toBeTruthy()
    expect(dirPanel!.className).toContain('bg-[var(--warn-10)]')
    expect(dirPanel!.className).toContain('border-l-[var(--color-warn)]')
    // Named chip: "Directory error" is what AT hears.
    const dirChip = dirPanel!.querySelector('[aria-label]')
    expect(dirChip?.getAttribute('aria-label')).toContain('사용 불가')
  })

  it('pairs connector API failures with a browser/server next action', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockRejectedValue(new Error('GET /api/v1/gate/connectors: 503 Service Unavailable'))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const warningPanel = container.querySelector('[data-connector-warning-panel]') as HTMLElement | null
    expect(warningPanel).not.toBeNull()
    const text = warningPanel!.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    expect(text).toContain('Connector API 사용 불가')
    expect(text).toContain('Cause: GET /api/v1/gate/connectors: 503 Service Unavailable')
    expect(text).toContain('Next: refresh the dashboard')
    expect(text).toContain('/api/v1/gate/connectors')
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

  it('shows the gateway machine-state chip when it adds info beyond the coarse label', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        connected: false,
        status: 'disconnected',
        gateway_state: 'reconnect_pending',
        status_source: 'in_process_gateway',
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

    const chip = container.querySelector('[data-gateway-state-chip]') as HTMLElement | null
    expect(chip).not.toBeNull()
    expect(chip!.textContent).toContain('reconnect_pending')
  })

  it('hides the gateway chip when the machine state merely repeats the coarse label', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [{
        ...sampleConnectorsResponse().connectors[0],
        connected: true,
        status: 'connected',
        gateway_state: 'connected',
        status_source: 'in_process_gateway',
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

    expect(container.querySelector('[data-gateway-state-chip]')).toBeNull()
  })

  it('mounts the message-flow section fed by gate status data', async () => {
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

    const flow = container.querySelector('[data-connector-flow="discord"]') as HTMLElement | null
    expect(flow).not.toBeNull()
    // Channel aggregate from sampleGateResponse: 12 in / 10 ok.
    expect(flow!.querySelector('[data-flow-stats]')?.textContent).toContain('12')
    // Per-keeper binding traffic row.
    expect(flow!.querySelector('[data-flow-bindings]')?.textContent).toContain('luna')
    // Recent gate event + binding audit history.
    expect(flow!.querySelector('[data-flow-events]')?.textContent).toContain('keeper_error')
    expect(flow!.querySelector('[data-flow-audit]')?.textContent).toContain('bind')
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
      .find(candidate => candidate.textContent?.trim() === '연결')
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
    // Discord (RFC-0203) and Slack (RFC-0317) are in-process and do not
    // render the sidecar-off panel anymore; use Telegram as the
    // representative external sidecar for this assertion. The in-process
    // hint case is covered by the follow-up test below.
    const telegramConnector = {
      ...sampleConnectorsResponse().connectors[0],
      connector_id: 'telegram',
      display_name: 'Telegram',
      channel: 'telegram',
      available: false,
      connected: false,
      stale: false,
      status: 'offline',
      status_path: '/tmp/telegram_status.json',
      configured_bindings: [],
    }
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [telegramConnector],
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
    expect(text).toContain('사이드카 미시작')
    expect(text).toContain('cd sidecars/telegram-bot && ./run.sh')
    expect(text).toContain('사이드카 status 파일이')
    expect(text).toContain('/tmp/telegram_status.json')
    expect(text).toContain('관찰되지 않았습니다')
    expect(text).toContain('Start')
    expect(text).toContain('status')
    expect(text).toContain('tail logs')

    // Regression guard for the screenshot bug: when a connector card's
    // brand accent is green (iMessage), the outer card renders a green
    // gradient; a neutral `bg-[var(--color-bg-elevated)]` panel sitting inside it
    // used to read as a "success" tint ("not started" painted green).
    // The panel now uses informational amber + a Portainer-style left
    // stripe so it's unambiguously "needs action" regardless of the
    // parent connector's brand color.
    const panel = container.querySelector('[data-sidecar-not-started-panel]') as HTMLElement | null
    expect(panel).toBeTruthy()
    expect(panel!.className).toContain('bg-[var(--warn-10)]')
    expect(panel!.className).toContain('border-l-[var(--color-warn)]')
    // And the explicit "Not running" status chip is the one AT users hear.
    const chip = panel!.querySelector('[data-sidecar-status-chip]')
    expect(chip).toBeTruthy()
    expect(chip!.getAttribute('aria-label')).toContain('실행 중 아님')
    expect(chip!.textContent).toContain('실행 중 아님')

    const copyLabels = Array.from(panel!.querySelectorAll<HTMLButtonElement>('[data-copy-button]'))
      .map(button => button.getAttribute('aria-label'))
    expect(copyLabels).toEqual([
      'Copy Telegram sidecar start command',
      'Copy Telegram sidecar tail logs command',
      'Copy Telegram sidecar status command',
      'Copy Telegram sidecar stop command',
    ])
  })

  // RFC-0203 §Phase 3 — Discord runs in-process. When the gateway
  // hasn't connected (e.g. DISCORD_BOT_TOKEN unset), the operator
  // sees the in-process hint panel instead of the sidecar-off panel,
  // and there are no Start/Stop buttons or run.sh hints anywhere.
  it('shows in-process unavailable hint for Discord (no sidecar Start panel, no run.sh)', async () => {
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
    // The new in-process hint replaces the sidecar Start panel.
    expect(text).toContain('서버 내장 게이트웨이')
    expect(text).toContain('DISCORD_BOT_TOKEN')
    expect(text).toContain('재기동')
    // None of the sidecar-only affordances should appear for discord.
    expect(text).not.toContain('사이드카 미시작')
    expect(text).not.toContain('cd sidecars/discord-bot && ./run.sh')

    // The in-process panel uses the same amber tone for visual
    // consistency with the sidecar-off panel, but it's a different
    // data attribute so existing sidecar-targeted CSS / hooks don't
    // accidentally apply.
    const sidecarPanel = container.querySelector('[data-sidecar-not-started-panel]')
    expect(sidecarPanel).toBeNull()
    const inProcessPanel = container.querySelector('[data-in-process-not-running-panel]') as HTMLElement | null
    expect(inProcessPanel).toBeTruthy()
    expect(inProcessPanel!.className).toContain('bg-[var(--warn-10)]')
    expect(inProcessPanel!.className).toContain('border-l-[var(--color-warn)]')

    const chip = inProcessPanel!.querySelector('[data-in-process-status-chip]')
    expect(chip).toBeTruthy()
    expect(chip!.textContent).toContain('연결되지 않음')

    // No Start/Stop button, no copyable run.sh command.
    expect(inProcessPanel!.querySelector('button[aria-label*="start"]')).toBeNull()
    expect(inProcessPanel!.querySelector('[data-copy-button]')).toBeNull()
    expect(container.querySelector('[aria-controls="sidecar-log-discord"]')).toBeNull()
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
    expect(text).toContain('설정된 키퍼 없음')

    // Sibling of the "Sidecar not started" panel (#8038). Same fix:
    // explicit amber override so the parent accent gradient (iMessage
    // green) doesn't paint a "no keepers" panel as success.
    const emptyPanel = container.querySelector('[data-no-keepers-empty-panel]') as HTMLElement | null
    expect(emptyPanel).toBeTruthy()
    expect(emptyPanel!.className).toContain('bg-[var(--warn-10)]')
    expect(emptyPanel!.className).toContain('border-l-[var(--color-warn)]')
    const chip = emptyPanel!.querySelector('[data-no-keepers-status-chip]')
    expect(chip).toBeTruthy()
    expect(chip!.getAttribute('aria-label')).toContain('설정된 키퍼 없음')
    expect(chip!.textContent).toContain('설정 필요')
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
    expect(novaText).not.toContain('gemini-3-flash-preview')
    expect(novaText).not.toContain('model ')
    expect(novaText).toContain('runtime keeper-nova-agent')
  })

  it('mounts under the v2 connector status surface class', async () => {
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

    const root = container.querySelector('.v2-connector-status')
    expect(root).not.toBeNull()
  })
})

describe('filterKeeperGroups', () => {
  // Shape-compatible sample. `filterKeeperGroups` only reads `name` and
  // `keeper.agent_name` so bindings
  // are allowed to be empty and `unknown` never matters.
  type GroupLike = {
    name: string
    keeper: {
      name: string
      active_model?: string
      model?: string
      primary_model?: string
      agent_name?: string
    } | null
    bindings: Array<{ channel_id: string; keeper_name: string }>
    unknown: boolean
  }

  function group(
    name: string,
    keeper: GroupLike['keeper'] = { name },
  ): GroupLike {
    return { name, keeper, bindings: [], unknown: false }
  }

  async function loadFilter() {
    // Fresh module — other tests may have mocked api/gate etc. We don't
    // need any mocks here; a raw re-import is fine.
    vi.resetModules()
    const module = await import('./connector-status')
    return module.filterKeeperGroups as (
      groups: readonly GroupLike[],
      query: string,
    ) => readonly GroupLike[]
  }

  it('returns the input reference unchanged for empty query', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [group('nova'), group('luna')]
    expect(filterKeeperGroups(rows, '')).toBe(rows)
  })

  it('returns the input reference unchanged for whitespace-only query', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [group('nova')]
    expect(filterKeeperGroups(rows, '   ')).toBe(rows)
  })

  it('matches on name case-insensitively', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [group('Nova'), group('luna'), group('atlas')]
    const filtered = filterKeeperGroups(rows, 'NOVA')
    expect(filtered).toHaveLength(1)
    expect(filtered[0]!.name).toBe('Nova')
  })

  it('does not match on active_model via substring', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [
      group('nova', { name: 'nova', active_model: 'gemini-3-flash-preview' }),
      group('luna', { name: 'luna', active_model: 'claude-opus' }),
    ]
    const filtered = filterKeeperGroups(rows, 'gemini')
    expect(filtered).toHaveLength(0)
  })

  it('does not fall back from active_model to model', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [
      group('nova', { name: 'nova', active_model: '   ', model: 'gemini-flash' }),
    ]
    const filtered = filterKeeperGroups(rows, 'gemini')
    expect(filtered).toHaveLength(0)
  })

  it('matches on agent_name runtime label when distinct from keeper name', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [
      group('nova', { name: 'nova', agent_name: 'keeper-nova-agent' }),
    ]
    expect(filterKeeperGroups(rows, 'keeper-nova-agent')).toHaveLength(1)
  })

  it('does not match agent_name when it equals the keeper name', async () => {
    // Runtime label helper returns '' when agent_name === name, so the
    // query should not match via the runtime field. It still matches on
    // the name field itself.
    const filterKeeperGroups = await loadFilter()
    const rows = [group('nova', { name: 'nova', agent_name: 'nova' })]
    expect(filterKeeperGroups(rows, 'nova')).toHaveLength(1)
    // But a query targeting only the runtime label must miss when no
    // fields contain it.
    const onlyRuntime = [
      group('nova', { name: 'nova', agent_name: 'nova' }),
    ]
    expect(filterKeeperGroups(onlyRuntime, 'keeper-nova-agent')).toEqual([])
  })

  it('returns an empty array when no rows match', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [group('nova'), group('luna')]
    expect(filterKeeperGroups(rows, 'nonexistent-zzz')).toEqual([])
  })

  it('handles null keeper (unknown groups) without throwing', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows: GroupLike[] = [
      { name: 'ghost', keeper: null, bindings: [], unknown: true },
    ]
    expect(filterKeeperGroups(rows, 'ghost')).toHaveLength(1)
    // Model and runtime are empty for null keeper — only name matches.
    expect(filterKeeperGroups(rows, 'gemini')).toEqual([])
  })

  it('does not mutate the input array', async () => {
    const filterKeeperGroups = await loadFilter()
    const rows = [group('nova'), group('luna'), group('atlas')]
    const originalOrder = rows.map(r => r.name)
    filterKeeperGroups(rows, 'luna')
    expect(rows.map(r => r.name)).toEqual(originalOrder)
    expect(rows).toHaveLength(3)
  })
})

describe('ConnectorStatusPanel v2 surface layout', () => {
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

  it('renders the keeper-v2 surface header, gate grid, audit log, and collapsed operator rollup', async () => {
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

    expect(container.querySelector('.cn-surf-head')).not.toBeNull()
    expect(container.querySelector('[data-testid="connector-gate-grid"]')).not.toBeNull()
    expect(container.querySelectorAll('[data-testid="connector-gate-card"]').length).toBe(4)
    expect(container.querySelector('[data-testid="connector-audit-log"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="connector-operations-rollup"]')).not.toBeNull()
    expect(container.querySelector('.cn-toolbar')).not.toBeNull()
    expect(container.querySelector('[data-testid="connector-search-input"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="connector-add-button"]')).toBeNull()
    expect(container.querySelector('[data-testid="connector-gate-strip"]')).not.toBeNull()
    expect(container.textContent).toContain('Gate')
    expect(container.textContent).toContain('외부 게이트 4개')
    expect(container.textContent).toContain('최근 감사 로그')
    expect(container.textContent).toContain('운영 상세')
    expect(container.textContent).not.toContain('Add connector')
  })

  it('routes backed channel keeper bindings to the keeper conversation', async () => {
    const originalHash = window.location.hash
    try {
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

      const bindingLink = container.querySelector<HTMLButtonElement>(
        '[data-testid="connector-binding-keeper-link"][data-binding-channel="123456"]',
      )
      expect(bindingLink).not.toBeNull()
      expect(bindingLink?.getAttribute('data-binding-keeper')).toBe('luna')
      expect(bindingLink?.textContent).toContain('luna')

      bindingLink!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await flushUi()

      expect(window.location.hash).toBe('#keepers?keeper=luna')
    } finally {
      window.location.hash = originalHash
      window.dispatchEvent(new HashChangeEvent('hashchange'))
    }
  })

  it('pins connector status pill mapping across the closed four-state domain', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const base = sampleConnectorsResponse().connectors[0]
    const connector = (
      connector_id: string,
      display_name: string,
      status: 'connected' | 'stale' | 'disconnected' | 'offline',
      available: boolean,
      connected: boolean,
      stale: boolean,
    ) => ({
      ...base,
      connector_id,
      display_name,
      channel: connector_id,
      status,
      available,
      connected,
      stale,
      configured_bindings: [],
      recent_audit: [],
    })
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [
        connector('discord', 'Discord', 'connected', true, true, false),
        connector('imessage', 'iMessage', 'stale', true, false, true),
        connector('slack', 'Slack', 'disconnected', true, false, false),
        connector('telegram', 'Telegram', 'offline', false, false, false),
      ],
      total: 4,
      active_count: 1,
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

    const card = (id: string) => container.querySelector(`[data-connector-card="${id}"]`) as HTMLElement | null
    const pill = (id: string) => card(id)?.querySelector('.cn-status-pill') as HTMLElement | null

    expect(card('discord')?.getAttribute('data-connector-card-state')).toBe('connected')
    expect(pill('discord')?.className).toContain('run')
    expect(pill('discord')?.textContent).toContain('Connected')

    expect(card('imessage')?.getAttribute('data-connector-card-state')).toBe('stale')
    expect(card('imessage')?.className).toContain('stale')
    expect(pill('imessage')?.className).toContain('pause')
    expect(pill('imessage')?.textContent).toContain('Stale')

    expect(card('slack')?.getAttribute('data-connector-card-state')).toBe('disconnected')
    expect(card('slack')?.className).toContain('down')
    expect(pill('slack')?.className).toContain('off')
    expect(pill('slack')?.textContent).toContain('Down')

    expect(card('telegram')?.getAttribute('data-connector-card-state')).toBe('offline')
    expect(card('telegram')?.className).toContain('down')
    expect(pill('telegram')?.className).toContain('off')
    expect(pill('telegram')?.textContent).toContain('Down')
  })

  it('filters connector tiles from the toolbar search input', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const discord = sampleConnectorsResponse().connectors[0]
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleConnectorsResponse({
      connectors: [
        discord,
        {
          ...discord,
          connector_id: 'imessage',
          display_name: 'iMessage',
          channel: 'imessage',
          status_path: '/tmp/imessage_status.json',
          binding_store_path: '/tmp/imessage_bindings.json',
          audit_path: '/tmp/imessage_binding_audit.jsonl',
          names_path: '/tmp/imessage_names.json',
          configured_bindings: [{ channel_id: 'imsg-workspace', keeper_name: 'nova' }],
          recent_audit: [],
        },
      ],
      total: 2,
      active_count: 2,
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

    expect(container.querySelectorAll('[data-overview-tile]').length).toBe(4)

    const searchInput = container.querySelector('[data-testid="connector-search-input"]') as HTMLInputElement
    searchInput.value = 'imessage'
    searchInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    expect(container.querySelector('[data-overview-tile="imessage"]')).not.toBeNull()
    expect(container.querySelector('[data-overview-tile="discord"]')).toBeNull()

    searchInput.value = ''
    searchInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    expect(container.querySelectorAll('[data-overview-tile]').length).toBe(4)
  })

  it('opens the detail config drawer from a tile config button', async () => {
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

    const configButton = container.querySelector<HTMLButtonElement>('button[aria-label="Discord 설정 열기"]')
    expect(configButton).not.toBeNull()
    configButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    const drawer = container.querySelector('[data-testid="connector-detail-drawer"]')
    expect(drawer).not.toBeNull()
    expect(drawer!.textContent).toContain('Discord 상태 및 설정')
    expect(drawer!.textContent).toContain('connection')
    expect(drawer!.textContent).toContain('config')
    expect(drawer!.textContent).toContain('events')
    expect(drawer!.textContent).toContain('연결 상태')
    expect(drawer!.textContent).toContain('Reply mode')
    expect(drawer!.textContent).toContain('채널 → keeper 바인딩')
    expect(drawer!.querySelector('[data-testid="connector-live-settings-summary"]')).not.toBeNull()
    expect(drawer!.querySelector('[data-testid="connector-reply-mode-summary"]')).not.toBeNull()
    expect(drawer!.querySelector('[data-testid="connector-binding-summary"]')).not.toBeNull()
    expect(drawer!.querySelector('[data-testid="connector-reply-mode-editor"]')).toBeNull()
    expect(drawer!.querySelector('[data-testid="connector-binding-editor"]')).toBeNull()
    expect(drawer!.querySelectorAll('[data-testid="connector-binding-summary-row"]').length).toBe(1)
    expect(drawer!.textContent).not.toContain('바인딩 추가')
    expect(drawer!.textContent).not.toContain('재발급')
    expect(drawer!.textContent).not.toContain('Test connection')

    const configTab = Array.from(drawer!.querySelectorAll('button')).find(b => b.textContent === 'config')
    expect(configTab).not.toBeUndefined()
    configTab!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(drawer!.textContent).toContain('server in-process')
    expect(drawer!.textContent).not.toContain('Test connection')
  })

  it('refreshes connector drawer read-only fields from the backend snapshot', async () => {
    const fetchGateStatus = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleGateResponse())
    const firstConnector = {
      ...sampleConnectorsResponse().connectors[0],
      bot_user_name: 'server bot initial',
    }
    const refreshedConnector = {
      ...firstConnector,
      bot_user_name: 'server bot refreshed',
      updated_at: '2026-04-03T00:01:00Z',
    }
    const fetchGateConnectors = vi.fn<() => Promise<unknown>>()
      .mockResolvedValueOnce(sampleConnectorsResponse({
        connectors: [firstConnector],
        total: 1,
        active_count: 1,
      }))
      .mockResolvedValueOnce(sampleConnectorsResponse({
        connectors: [refreshedConnector],
        total: 1,
        active_count: 1,
      }))
    const fetchGateKeepers = vi.fn<() => Promise<unknown>>().mockResolvedValue(sampleKeepersResponse())
    const last = signal<unknown>(null)

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      fetchGateStatus,
      fetchGateConnectors,
      fetchGateKeepers,
      lastEvent: last,
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    const configButton = container.querySelector<HTMLButtonElement>('button[aria-label="Discord 설정 열기"]')
    expect(configButton).not.toBeNull()
    configButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(container.querySelector('input[aria-label="connector bot"]')).toBeNull()
    expect(container.querySelector('[data-testid="connector-readonly-bot-row"]')?.textContent).toContain('server bot initial')

    last.value = { type: 'connector_refresh' }
    await new Promise(resolve => setTimeout(resolve, 2100))
    await flushUi()

    expect(fetchGateConnectors).toHaveBeenCalledTimes(2)
    expect(container.querySelector('[data-testid="connector-readonly-bot-row"]')?.textContent).toContain('server bot refreshed')
  })
})
