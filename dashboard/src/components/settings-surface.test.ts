// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import {
  SettingsSurface,
  checkSettingsMcpEndpoint,
  checkSettingsStoreUrl,
  checkSettingsWorktreeBase,
  mcpExposedToolNames,
  logEntryToSysRow,
  logRowStatus,
  normalizeSettingsSection,
} from './settings-surface'
import type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  LogEntry,
  RuntimeDefaultsResponse,
} from '../api/dashboard'
import type { GateConnectorsData, GateConnectorInfo } from '../api/gate'
import type { Keeper, KeeperConfig } from '../types'
import { DashboardMain } from './dashboard-shell'
import { route } from '../router'
import { connected } from '../sse'

const MOCK_RUNTIME_PATH = 'fixture/config/runtime.toml'
import { dashboardLoading } from '../store'
import { keepers } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'
import { resetDevTokenBootstrap } from '../api/dev-token'

const apiMock = vi.hoisted(() => ({
  fetchLogs: vi.fn(),
  fetchDashboardTools: vi.fn(),
  fetchRuntimeDefaults: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
  fetchKeeperConfig: vi.fn(),
  patchKeeperConfig: vi.fn(),
}))

const gateApiMock = vi.hoisted(() => ({
  fetchGateConnectors: vi.fn(),
}))

const keeperApiMock = vi.hoisted(() => ({
  fetchKeepersComposite: vi.fn(),
}))

const promptApiMock = vi.hoisted(() => ({
  clearPromptOverride: vi.fn(async () => ({ ok: true, message: 'override cleared' })),
  fetchDashboardPrompts: vi.fn(async () => ({
    prompts: [
      {
        key: 'keeper.world',
        category: 'keeper',
        description: 'Shared world prompt',
        current: 'Hello {{keeper}} in {{namespace}}',
        default: 'Hello {{keeper}} in {{namespace}}',
        effective: 'Hello {{keeper}} in {{namespace}}',
        file_value: 'Hello {{keeper}} in {{namespace}}',
        override_value: null,
        file_path: 'fixture/config/prompts/keeper.world.md',
        file_exists: true,
        source: 'file' as const,
        has_override: false,
        char_count: 35,
        required_file: true,
        template_variables: ['keeper', 'namespace'],
      },
    ],
  })),
  savePromptOverride: vi.fn(async () => ({ ok: true, message: 'override set' })),
}))

vi.mock('../api/dashboard.js', async () => {
  const actual = await vi.importActual<typeof import('../api/dashboard')>('../api/dashboard')
  return {
    ...actual,
    fetchLogs: apiMock.fetchLogs,
    fetchDashboardTools: apiMock.fetchDashboardTools,
    fetchRuntimeDefaults: apiMock.fetchRuntimeDefaults,
    fetchRuntimeProviders: apiMock.fetchRuntimeProviders,
    fetchKeeperConfig: apiMock.fetchKeeperConfig,
    patchKeeperConfig: apiMock.patchKeeperConfig,
  }
})

vi.mock('../api/gate', async () => {
  const actual = await vi.importActual<typeof import('../api/gate')>('../api/gate')
  return {
    ...actual,
    fetchGateConnectors: gateApiMock.fetchGateConnectors,
  }
})

vi.mock('../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper')>('../api/keeper')
  return {
    ...actual,
    fetchKeepersComposite: keeperApiMock.fetchKeepersComposite,
  }
})

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    clearPromptOverride: promptApiMock.clearPromptOverride,
    fetchDashboardPrompts: promptApiMock.fetchDashboardPrompts,
    savePromptOverride: promptApiMock.savePromptOverride,
  }
})

function makeLogEntry(overrides: Partial<LogEntry> = {}): LogEntry {
  return {
    seq: 1,
    ts: '2026-06-21T16:24:51Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    message: 'booted',
    keeper_name: null,
    turn_id: null,
    category: null,
    details: null,
    ...overrides,
  }
}

function makeToolItem(overrides: Partial<DashboardToolInventoryItem> = {}): DashboardToolInventoryItem {
  return {
    name: 'tool',
    description: '',
    category: 'uncategorized',
    enabled_in_current_mode: false,
    direct_call_allowed: false,
    doc_refs: [],
    prompt_hints: [],
    surfaces: [],
    visibility: 'public',
    lifecycle: 'stable',
    implementationStatus: 'implemented',
    tier: 'standard',
    ...overrides,
  }
}

function makeRuntimeDefaults(
  overrides: Partial<RuntimeDefaultsResponse> = {},
): RuntimeDefaultsResponse {
  return {
    generated_at_iso: '2026-06-21T00:00:00Z',
    dashboard_surface: '/api/v1/dashboard/runtime-defaults',
    source: 'runtime_config',
    config_path: '/cfg/runtime.toml',
    default_runtime_id: 'rt-a',
    default_model: 'm1',
    default_max_context: 128000,
    runtimes: [
      { id: 'rt-a', provider: 'P', model: 'm1', max_context: 128000, is_default: true },
      { id: 'rt-b', provider: 'P', model: 'm2', max_context: 128000, is_default: false },
      { id: 'rt-c', provider: 'P', model: 'm3', max_context: 128000, is_default: false },
    ],
    model_routing: {
      keeper_assignments: [{ keeper: 'analyst', runtime_id: 'rt-b' }],
      librarian_runtime_id: null,
      cross_verifier_runtime_id: null,
      media_failover: [],
    },
    ...overrides,
  }
}

function makeRuntimeProvider(
  overrides: Partial<DashboardRuntimeProviderSnapshot> = {},
): DashboardRuntimeProviderSnapshot {
  return {
    provider: 'rt-a',
    runtime_id: 'rt-a',
    provider_id: 'provider-a',
    provider_display_name: 'Provider A',
    model_id: 'm1',
    model_api_name: 'm1',
    protocol: 'openai-http',
    transport: 'http',
    kind: 'cloud',
    runtime_kind: 'cloud',
    auth_kind: 'env',
    status: 'configured',
    available: true,
    is_default_runtime: true,
    max_context: 128000,
    tools_support: true,
    thinking_support: false,
    streaming: true,
    model_count: 1,
    models: ['m1'],
    source: 'runtime.toml',
    endpoint_url: 'https://runtime.example/v1',
    note: null,
    discovery: null,
    ...overrides,
  }
}

function makeRuntimeProviders(
  overrides: Partial<DashboardRuntimeProvidersResponse> = {},
): DashboardRuntimeProvidersResponse {
  return {
    updated_at: '2026-06-21T00:00:00Z',
    summary: {
      providers: 1,
      runtimes: 2,
      local_models: 0,
      cloud_models: 2,
      cli_models: 0,
      default_runtime_id: 'rt-a',
    },
    providers: [
      makeRuntimeProvider(),
      makeRuntimeProvider({
        provider: 'rt-b',
        runtime_id: 'rt-b',
        provider_display_name: 'Provider B',
        model_id: 'm2',
        model_api_name: 'm2',
        is_default_runtime: false,
        thinking_support: true,
      }),
    ],
    assignment_governance: null,
    config_path: '/cfg/runtime.toml',
    ...overrides,
  }
}

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    status: 'idle',
    sandbox_profile: 'local',
    ...overrides,
  }
}

function makeKeeperConfig(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  return {
    name: 'sangsu',
    active_goal_ids: [],
    autoboot_enabled: true,
    max_context_override: null,
    limits: {
      min_context_override_tokens: null,
      max_context_override_tokens: null,
    },
    sandbox_profile: 'local',
    network_mode: 'inherit',
    sandbox_last_error: null,
    allowed_paths: ['workspace/masc'],
    effective_allowed_paths: ['/Users/dancer/me/workspace/yousleepwhen/masc'],
    prompt: {
      goal: '',
      instructions: '',
      system_prompt_blocks: {
        constitution: { key: 'keeper.constitution', source: 'file', text: '' },
        world: { key: 'keeper.world', source: 'file', text: '' },
        capabilities: { key: 'keeper.capabilities', source: 'file', text: '' },
      },
      effective_system_prompt: '',
      unified_system_prompt: '',
      unified_user_message_preview: '',
    },
    execution: {
      models: [],
      active_model: '',
      active_model_label: null,
      last_model_used_label: null,
      per_provider_timeout_sec: null,
      per_provider_timeout_mode: 'turn_budget_default',
      verify: false,
      selected_runtime_id: 'rt-a',
      selected_runtime_canonical: 'rt-a',
      runtime_options: ['rt-a', 'rt-b'],
    },
    compaction: {
      profile: 'off',
      ratio_gate: 0.85,
      message_gate: 0,
      token_gate: 0,
      cooldown_sec: 0,
    },
    proactive: {
      enabled: false,
      idle_sec: 0,
      cooldown_sec: 0,
    },
    drift: {
      status: 'unwired',
      enabled: null,
      min_turn_gap: null,
      count_total: null,
      last_reason: null,
    },
    handoff: {
      auto: false,
      threshold: 0.85,
      cooldown_sec: 0,
    },
    runtime: {
      paused: false,
      registered: true,
      keepalive_running: true,
      registry_state: 'registered',
      fiber_health: 'idle',
      runtime_blocker_class: null,
      active_model_label: null,
      last_model_used_label: null,
      runtime_blocker_summary: null,
      runtime_blocker_continue_gate: null,
    },
    runtime_trust: null,
    workspace: {
      mention_targets: [],
      bound_workspace_ids: [],
      active_goal_ids: [],
      active_goals: [],
      active_goal_count: 0,
      missing_active_goal_ids: [],
    },
    tools: {
      tool_access: [],
      resolved_allowlist: [],
      tool_denylist: [],
      active_masc_tool_count: 0,
      active_keeper_tool_count: 0,
      total_active: 0,
    },
    sources: {
      live_meta_path: '/Users/dancer/me/.masc/config/keepers/sangsu.toml',
      default_manifest_path: null,
      default_source_kind: 'toml',
      precedence: [],
      has_live_override: true,
      override_fields: [],
    },
    metrics: {
      generation: 1,
      total_turns: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_tokens: 0,
      total_cost_usd: 0,
      last_model_used: '',
      last_input_tokens: 0,
      last_output_tokens: 0,
      last_total_tokens: 0,
      last_latency_ms: null,
      last_total_tokens_per_sec: null,
      last_output_tokens_per_sec: null,
      compaction_count: 0,
    },
    ...overrides,
  }
}

function makeGateConnector(overrides: Partial<GateConnectorInfo> = {}): GateConnectorInfo {
  return {
    connector_id: 'discord',
    display_name: 'Discord',
    channel: 'discord',
    capabilities: ['bindings'],
    status: 'connected',
    available: true,
    connected: true,
    stale: false,
    stale_after_sec: 60,
    gateway_state: 'connected',
    status_source: 'in_process_gateway',
    error: '',
    status_path: '/state/discord.json',
    binding_store_path: '/bindings/discord.json',
    audit_path: '/audit/discord.jsonl',
    updated_at: '2026-06-30T00:00:00Z',
    reply_mode: 'mention_or_thread',
    self_chat_guid: '',
    last_ready_at: '2026-06-30T00:00:00Z',
    bot_user_name: 'masc-bot',
    bot_user_id: 'bot-1',
    guild_count: 1,
    gate_base_url: 'https://gate.masc.local',
    gate_healthy: true,
    gate_health_checked_at: '2026-06-30T00:00:00Z',
    binding_source: '/bindings/discord.json',
    runtime_bindings_count: 1,
    pid: 123,
    configured_bindings: [{ channel_id: 'C1', keeper_name: 'sangsu' }],
    recent_audit: [],
    storage_paths: {
      status_path: '/state/discord.json',
      binding_store_path: '/bindings/discord.json',
      audit_path: '/audit/discord.jsonl',
      names_path: '/names/discord.json',
    },
    runtime_summary: {
      available: true,
      connected: true,
      stale: false,
      stale_after_sec: 60,
      status: 'connected',
      error: '',
      updated_at: '2026-06-30T00:00:00Z',
      reply_mode: 'mention_or_thread',
      self_chat_guid: '',
      last_ready_at: '2026-06-30T00:00:00Z',
      bot_user_name: 'masc-bot',
      bot_user_id: 'bot-1',
      guild_count: 1,
      gate_base_url: 'https://gate.masc.local',
      gate_healthy: true,
      gate_health_checked_at: '2026-06-30T00:00:00Z',
      pid: 123,
    },
    binding_summary: {
      binding_source: '/bindings/discord.json',
      runtime_bindings_count: 1,
      configured_bindings_count: 1,
    },
    observed_channel: null,
    names_path: '/names/discord.json',
    names: {
      guild_names: {},
      channel_names: {},
      channel_to_guild: {},
      updated_at: '',
    },
    ...overrides,
  }
}

function makeGateConnectors(overrides: Partial<GateConnectorsData> = {}): GateConnectorsData {
  return {
    connectors: [makeGateConnector()],
    total: 1,
    active_count: 1,
    discord_trigger_policy: 'mention_or_thread',
    generated_at: '2026-06-30T00:00:00Z',
    ...overrides,
  }
}

function stubRuntimeDefaults(value: RuntimeDefaultsResponse = makeRuntimeDefaults()) {
  apiMock.fetchRuntimeDefaults.mockResolvedValue(value)
}

function stubRuntimeRawFetch(sourceText = '[runtime]\ndefault = "rt-a"\n') {
  vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
    const requestUrl =
      typeof input === 'string'
        ? input
        : input instanceof URL
          ? input.href
          : typeof (input as { url?: unknown }).url === 'string'
            ? (input as { url: string }).url
            : ''
    const path = requestUrl.startsWith('http')
      ? new URL(requestUrl).pathname
      : requestUrl.split('?')[0] ?? requestUrl
    if (path === '/api/v1/dashboard/dev-token') {
      return new Response(JSON.stringify({ token: 'dev-token', actor: 'dashboard' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    if (path === '/api/v1/runtime/config/raw') {
      return new Response(JSON.stringify({
        ok: true,
        path: MOCK_RUNTIME_PATH,
        file_name: 'runtime.toml',
        source_text: sourceText,
        reloaded: false,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    return new Response(JSON.stringify({ message: `unexpected ${path}` }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }))
}

function sourceTextForRouting(): string {
  return `[runtime]
default = "p.m1"
librarian = "p.m2"
cross_verifier = "p.m2"

[providers.p]
display-name = "Provider"
protocol = "openai-http"
endpoint = "https://runtime.example/v1"

[models.m1]
api-name = "m1"
max-context = 128000
tools-support = true
thinking-support = false
json-support = true
streaming = true

[models.m2]
api-name = "m2"
max-context = 128000
tools-support = true
thinking-support = true
json-support = true
streaming = true

[p.m1]
is-default = true

[p.m2]
`
}

function stubEmptyApi() {
  apiMock.fetchLogs.mockResolvedValue({ total: 0, entries: [] })
  apiMock.fetchDashboardTools.mockResolvedValue({ tool_inventory: { count: 0, tools: [] } })
  stubRuntimeDefaults()
  apiMock.fetchRuntimeProviders.mockResolvedValue(makeRuntimeProviders())
  apiMock.fetchKeeperConfig.mockResolvedValue(makeKeeperConfig())
  apiMock.patchKeeperConfig.mockImplementation(async (_name: string, payload: Partial<KeeperConfig>) =>
    makeKeeperConfig(payload),
  )
  gateApiMock.fetchGateConnectors.mockResolvedValue(makeGateConnectors())
  keeperApiMock.fetchKeepersComposite.mockResolvedValue({
    generated_at: '2026-06-30T00:00:00Z',
    count: 1,
    snapshots: [{ keeper: 'sangsu' }],
  })
}

const navigate = vi.fn()
vi.mock('../router', async () => {
  const actual = await vi.importActual<typeof import('../router')>('../router')
  return {
    ...actual,
    navigate: (...args: Parameters<typeof navigate>) => {
      navigate(...args)
      return actual.navigate(args[0], args[1])
    },
  }
})

describe('SettingsSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMock.fetchLogs.mockReset()
    apiMock.fetchDashboardTools.mockReset()
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeProviders.mockReset()
    apiMock.fetchKeeperConfig.mockReset()
    apiMock.patchKeeperConfig.mockReset()
    gateApiMock.fetchGateConnectors.mockReset()
    keeperApiMock.fetchKeepersComposite.mockReset()
    promptApiMock.clearPromptOverride.mockClear()
    promptApiMock.fetchDashboardPrompts.mockClear()
    promptApiMock.savePromptOverride.mockClear()
    stubEmptyApi()
    keepers.value = [makeKeeper()]
    window.location.hash = '#settings'
    route.value = { tab: 'settings', params: {}, postId: null }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    navigate.mockClear()
    resetDevTokenBootstrap()
    sessionStorage.clear()
    keepers.value = []
    vi.unstubAllGlobals()
    vi.unstubAllEnvs()
  })

  it('renders the surface and category navigation', () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('.v2-shell-surface')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-surface"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-account"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-runtime"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-logs"]')).not.toBeNull()
  })

  it('applies StyleSeed surface and card classes', () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('.v2-shell-surface.ss-surface.bg-surface-page.text-text-primary')).not.toBeNull()
    expect(container.querySelector('.set-card-b.ss-card')).not.toBeNull()
  })

  it('switches sections when category navigation is clicked', async () => {
    render(html`<${SettingsSurface} />`, container)

    const title = () => container.querySelector('[data-testid="settings-section-title"]') as HTMLElement
    expect(title().textContent).toBe('계정')

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    expect(title().textContent).toBe('런타임 기본값')
    expect(runtimeNav.getAttribute('data-active')).toBe('true')
    expect(navigate).toHaveBeenLastCalledWith('settings', { section: 'runtime' })

    const accountNav = container.querySelector('[data-testid="settings-nav-account"]') as HTMLElement
    await fireEvent.click(accountNav)

    expect(title().textContent).toBe('계정')
    expect(navigate).toHaveBeenLastCalledWith('settings', {})
  })

  it('selects a valid section from the dashboard route', () => {
    route.value = { tab: 'settings', params: { section: 'logs' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('관측 · 시스템 로그')
    expect(container.querySelector('[data-testid="settings-nav-logs"]')?.getAttribute('data-active')).toBe('true')
    expect(container.querySelector('[data-testid="log-viewer"]')).not.toBeNull()
  })

  it('renders the theme switch inside the display section (moved out of the top bar)', () => {
    route.value = { tab: 'settings', params: { section: 'display' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('표시')
    const themeButton = [...container.querySelectorAll('button')]
      .find(b => /DARK|STYLESEED|PAPER/.test(b.textContent ?? ''))
    expect(themeButton).toBeTruthy()
  })

  it('falls invalid settings sections back to account without a fake subsection', () => {
    expect(normalizeSettingsSection('not-real')).toBe('account')
    route.value = { tab: 'settings', params: { section: 'not-real' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('계정')
    expect(container.querySelector('[data-testid="settings-nav-account"]')?.getAttribute('data-active')).toBe('true')
  })

  it('syncs when the dashboard route section changes while mounted', async () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('계정')

    route.value = { tab: 'settings', params: { section: 'logs' }, postId: null }

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('관측 · 시스템 로그')
    })
  })

  it('marks unbacked settings sections as local preview controls instead of fake saved actions', async () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('local preview only')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-settings-mode')).toBe('local')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.textContent).not.toContain('Save changes')
    expect(container.textContent).not.toContain('Reissue')
    expect(container.textContent).not.toContain('Log out')
    expect(container.querySelector('[data-testid="token-toggle"]')).toBeNull()
    expect(container.querySelector<HTMLInputElement>('.set-path .set-input')?.readOnly).toBe(true)

    const policyNav = container.querySelector('[data-testid="settings-nav-policy"]') as HTMLElement
    await fireEvent.click(policyNav)

    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('local preview only')
    expect(container.querySelector('[data-testid="settings-preview-badge"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="set-verify"]')).toBeNull()
  })

  it('local preview segmented controls update visible state when clicked', async () => {
    render(html`<${SettingsSurface} />`, container)

    const never = Array.from(container.querySelectorAll<HTMLButtonElement>('.set-seg-b'))
      .find(button => button.textContent === '안 함')
    expect(never).toBeTruthy()
    expect(never?.disabled).toBe(false)

    await fireEvent.click(never as HTMLButtonElement)

    expect(never?.getAttribute('data-active')).toBe('true')
  })

  it('local preview text inputs are editable and reflected in dependent text', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-mcp"]') as HTMLElement)

    const input = container.querySelector<HTMLInputElement>('[data-testid="settings-mcp-endpoint-input"]')
    expect(input).toBeTruthy()
    expect(input?.readOnly).toBe(false)

    await fireEvent.input(input as HTMLInputElement, {
      target: { value: 'http://127.0.0.1:7777/mcp' },
    })

    expect(input?.value).toBe('http://127.0.0.1:7777/mcp')
    expect(container.querySelector('.set-mcp-detail')?.textContent).toContain('POST http://127.0.0.1:7777/mcp')
    expect(container.querySelector('[data-testid="settings-preview-badge"]')?.textContent).toBe('local only')

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)

    expect(container.querySelector<HTMLInputElement>('[data-testid="settings-mcp-endpoint-input"]')?.value).toBe('http://127.0.0.1:7777/mcp')
  })

  it('edits sandbox from live keeper config instead of fake global controls', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-sandbox"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('keeper config live-backed')
      expect(container.querySelector('[data-testid="settings-sandbox-profile"]')).not.toBeNull()
    })

    expect(container.querySelector('[data-testid="settings-allowed-domains-input"]')).toBeNull()
    expect(container.textContent).not.toContain('Allowed domains')
    expect(container.textContent).not.toContain('Resource limits')

    const profile = container.querySelector<HTMLSelectElement>('[data-testid="settings-sandbox-profile"]')
    const network = container.querySelector<HTMLSelectElement>('[data-testid="settings-sandbox-network"]')
    const allowedPaths = container.querySelector<HTMLTextAreaElement>('[data-testid="settings-sandbox-allowed-paths"]')
    expect(profile).toBeTruthy()
    expect(network).toBeTruthy()
    expect(allowedPaths).toBeTruthy()

    ;(profile as HTMLSelectElement).value = 'docker'
    await fireEvent.input(profile as HTMLSelectElement)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-sandbox-network"]')?.textContent).toContain('none')
    })
    const updatedNetwork = container.querySelector<HTMLSelectElement>('[data-testid="settings-sandbox-network"]')
    ;(updatedNetwork as HTMLSelectElement).value = 'none'
    await fireEvent.input(updatedNetwork as HTMLSelectElement)
    await fireEvent.input(allowedPaths as HTMLTextAreaElement, {
      target: { value: 'workspace/oas\nworkspace/oas\n  ' },
    })

    const save = container.querySelector<HTMLButtonElement>('[data-testid="settings-sandbox-save"]')
    expect(save).toBeTruthy()
    expect(save?.disabled).toBe(false)
    await fireEvent.click(save as HTMLButtonElement)

    await waitFor(() => {
      expect(apiMock.patchKeeperConfig).toHaveBeenCalledWith('sangsu', {
        sandbox_profile: 'docker',
        network_mode: 'none',
        allowed_paths: ['workspace/oas'],
      })
    })
    expect(container.querySelector('[data-testid="settings-sandbox-source"]')?.textContent).toContain('/Users/dancer/me/.masc/config/keepers/sangsu.toml')
  })

  it('falls back to fleet composite keeper names when sandbox opens before the keeper store is hydrated', async () => {
    keepers.value = []
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-sandbox"]') as HTMLElement)

    await waitFor(() => {
      expect(keeperApiMock.fetchKeepersComposite).toHaveBeenCalledTimes(1)
      expect(apiMock.fetchKeeperConfig).toHaveBeenCalledWith('sangsu')
      expect(container.querySelector('[data-testid="settings-sandbox-profile"]')).not.toBeNull()
    })
    expect(container.querySelector<HTMLSelectElement>('[data-testid="settings-sandbox-keeper-select"]')?.value).toBe('sangsu')
    expect(container.querySelector('[data-testid="settings-sandbox-empty"]')).toBeNull()
  })

  it('renders gate connectors from the live connector payload without local toggles', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-gate"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('gate connector live-backed')
      expect(container.querySelector('[data-testid="settings-gate-connectors"]')).not.toBeNull()
    })

    expect(container.querySelector('[data-testid="gate-live-summary"]')?.textContent).toContain('1/1 active')
    expect(container.querySelector('[data-testid="settings-gate-discord-trigger"]')?.textContent).toBe('mention_or_thread')
    expect(container.querySelector('[data-testid="settings-gate-base-live"]')?.textContent).toContain('https://gate.masc.local')

    const connectorCards = Array.from(container.querySelectorAll('[data-testid="settings-gate-connector"]'))
    expect(connectorCards.length).toBe(1)
    expect(connectorCards[0]?.textContent).toContain('discord')
    expect(connectorCards[0]?.textContent).toContain('Discord')
    expect(connectorCards[0]?.textContent).toContain('bindings 1')
    expect(container.textContent).not.toContain('Amplitude')
    expect(container.querySelector('[data-testid="settings-preview-badge"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-toggle"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-trigger"]')).toBeNull()

    await fireEvent.click(container.querySelector('[data-testid="settings-connectors-link"]') as HTMLButtonElement)
    expect(navigate).toHaveBeenLastCalledWith('connectors')
  })

  it('paths local preview values can be format-checked without claiming live verification', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)

    expect(container.textContent).toContain('format-checked only')
    expect(container.textContent).not.toContain('Each item can be verified')

    await fireEvent.click(container.querySelector('[data-testid="settings-path-check-mcp"]') as HTMLElement)
    await fireEvent.click(container.querySelector('[data-testid="settings-path-check-store"]') as HTMLElement)
    await fireEvent.click(container.querySelector('[data-testid="settings-path-check-worktree"]') as HTMLElement)

    expect(container.querySelector('[data-testid="settings-path-check-result-mcp"]')?.textContent).toBe('valid MCP URL')
    expect(container.querySelector('[data-testid="settings-path-check-result-mcp"]')?.getAttribute('data-ok')).toBe('true')
    expect(container.querySelector('[data-testid="settings-path-check-result-store"]')?.textContent).toBe('valid store URL')
    expect(container.querySelector('[data-testid="settings-path-check-result-store"]')?.getAttribute('data-ok')).toBe('true')
    expect(container.querySelector('[data-testid="settings-path-check-result-worktree"]')?.textContent).toBe('valid local path')
    expect(container.querySelector('[data-testid="settings-path-check-result-worktree"]')?.getAttribute('data-ok')).toBe('true')

    const storeInput = container.querySelector<HTMLInputElement>('[data-testid="settings-store-url-input"]')
    await fireEvent.input(storeInput as HTMLInputElement, {
      target: { value: 'not-a-url' },
    })
    await fireEvent.click(container.querySelector('[data-testid="settings-path-check-store"]') as HTMLElement)

    expect(container.querySelector('[data-testid="settings-path-check-result-store"]')?.textContent).toBe('invalid URL')
    expect(container.querySelector('[data-testid="settings-path-check-result-store"]')?.getAttribute('data-ok')).toBe('false')
  })

  it('renders runtime settings as a live-backed entry point instead of fake local controls', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml live-backed')
      expect(container.querySelector('[data-testid="runtime-settings-live"]')).not.toBeNull()
      expect(container.querySelector('[data-testid="runtime-settings-edit"]')).not.toBeNull()
    })
    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.querySelector('[data-testid="set-toggle"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-seg"]')).toBeNull()
  })

  it('opens runtime management from the runtime overview entry point', async () => {
    vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
      const requestUrl =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.href
            : typeof (input as { url?: unknown }).url === 'string'
              ? (input as { url: string }).url
              : ''
      const path = requestUrl.startsWith('http')
        ? new URL(requestUrl).pathname
        : requestUrl.split('?')[0] ?? requestUrl
      if (path === '/api/v1/dashboard/dev-token') {
        return new Response(JSON.stringify({ token: 'dev-token', actor: 'dashboard' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (path === '/api/v1/runtime/config/raw') {
        return new Response(JSON.stringify({
          ok: true,
          path: MOCK_RUNTIME_PATH,
          file_name: 'runtime.toml',
          source_text: '[runtime]\ndefault = "rt-a"\n',
          reloaded: false,
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ message: `unexpected ${path}` }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-settings-edit"]')).not.toBeNull()
    })
    await fireEvent.click(container.querySelector('[data-testid="runtime-settings-edit"]') as HTMLElement)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('런타임 관리')
    expect(navigate).toHaveBeenLastCalledWith('settings', { section: 'runtimes' })
  })

  it('runtime overview shows resolved defaults and the live provider catalog', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-default-runtime"]')?.textContent).toBe('rt-a')
      expect(container.querySelector('[data-testid="runtime-default-model"]')?.textContent).toBe('m1')
      expect(container.querySelector('[data-testid="runtime-settings-config-path"]')?.textContent).toContain('/cfg/runtime.toml')
      const cards = Array.from(container.querySelectorAll('[data-testid="runtime-catalog-card"]'))
      expect(cards.length).toBe(2)
      expect(cards.map(card => card.textContent)).toEqual([
        expect.stringContaining('Provider A'),
        expect.stringContaining('Provider B'),
      ])
      expect(container.querySelector('[data-testid="runtime-catalog-default"]')?.textContent).toBe('default')
    })
    expect(container.querySelector('[data-testid="runtime-default-context"]')).toBeNull()
    expect(container.textContent).not.toContain('oas·seoul-1')
  })

  it('routing section opens the live runtime.toml routing editor', async () => {
    keepers.value = [makeKeeper(), makeKeeper({ name: 'mad-improver', status: 'running' })]
    stubRuntimeRawFetch(`${sourceTextForRouting()}

[runtime.assignments]
sangsu = "p.m2"
mad-improver = "p.m1"
`)
    render(html`<${SettingsSurface} />`, container)

    const routingNav = container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement
    await fireEvent.click(routingNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml live-backed')
      expect(container.querySelector('[data-testid="runtime-toml-editor"]')).not.toBeNull()
      expect(container.querySelector('[data-testid="runtime-section-routing"]')).not.toBeNull()
      expect(container.querySelector('[data-testid="runtime-environment-save"]')).not.toBeNull()
    })
    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('모델 라우팅')
    expect(container.querySelector('[data-testid="runtime-toml-section-title"]')?.textContent).toBe('라우팅')
    expect(container.textContent).toContain('memory-os 라이브러리안')
    expect(container.textContent).toContain('cross-verifier')
    expect(container.textContent).not.toContain('Read-only')
    expect(container.querySelectorAll('[data-testid="routing-assignment"]').length).toBe(0)
  })

  it('routing section reports empty runtime.toml bindings without fabricating rows', async () => {
    stubRuntimeRawFetch('[runtime]\ndefault = "rt-a"\n')
    render(html`<${SettingsSurface} />`, container)

    const routingNav = container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement
    await fireEvent.click(routingNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-environment-empty"]')).not.toBeNull()
    })
    expect(container.querySelectorAll('[data-testid="routing-assignment"]').length).toBe(0)
  })

  it('renders prompt settings from the live prompt registry instead of prototype placeholders', async () => {
    render(html`<${SettingsSurface} />`, container)

    const promptsNav = container.querySelector('[data-testid="settings-nav-prompts"]') as HTMLElement
    await fireEvent.click(promptsNav)

    await waitFor(() => {
      expect(promptApiMock.fetchDashboardPrompts).toHaveBeenCalledTimes(1)
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('prompt registry live-backed')
    })

    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.querySelector('[data-testid="prompt-registry-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-prompt-preset-switcher]')).not.toBeNull()
    expect(container.querySelector('[data-prompt-destinations]')?.textContent).toContain('System rules')
    expect(container.textContent).toContain('{{keeper}}')
    expect(container.textContent).not.toContain('System (base) — what a keeper is')
    expect(container.textContent).not.toContain('World prompt — shared world·rules')
  })

  it('log filter chips filter live rows from the ring', async () => {
    // 6 ring entries mapped to rows: tool(/masc_/)=3, success(ok)=3, failure(fail)=2.
    apiMock.fetchLogs.mockResolvedValue({
      total: 6,
      entries: [
        makeLogEntry({ seq: 6, level: 'INFO', message: 'masc_start 완료' }),
        makeLogEntry({ seq: 5, level: 'INFO', message: 'masc_compact 완료' }),
        makeLogEntry({ seq: 4, level: 'WARN', message: '컨텍스트 91% — compact 예약' }),
        makeLogEntry({ seq: 3, level: 'ERROR', message: 'masc_trace_window 실패' }),
        makeLogEntry({ seq: 2, level: 'ERROR', message: 'restart failed (3/3)' }),
        makeLogEntry({ seq: 1, level: 'INFO', message: 'handoff 시작' }),
      ],
    })

    render(html`<${SettingsSurface} />`, container)

    const logsNav = container.querySelector('[data-testid="settings-nav-logs"]') as HTMLElement
    await fireEvent.click(logsNav)

    const allRows = () => container.querySelectorAll('[data-testid="log-row"]')
    await waitFor(() => expect(allRows().length).toBe(6))

    const toolFilter = container.querySelector('[data-filter="tool"]') as HTMLButtonElement
    await fireEvent.click(toolFilter)
    expect(allRows().length).toBe(3)

    const successFilter = container.querySelector('[data-filter="success"]') as HTMLButtonElement
    await fireEvent.click(successFilter)
    expect(allRows().length).toBe(3)

    const failureFilter = container.querySelector('[data-filter="failure"]') as HTMLButtonElement
    await fireEvent.click(failureFilter)
    expect(allRows().length).toBe(2)

    const allFilter = container.querySelector('[data-filter="all"]') as HTMLButtonElement
    await fireEvent.click(allFilter)
    expect(allRows().length).toBe(6)
  })

  it('shows the live MCP exposed-tools list from the capability registry', async () => {
    apiMock.fetchDashboardTools.mockResolvedValue({
      tool_inventory: {
        count: 2,
        tools: [
          makeToolItem({ name: 'masc_handoff', surfaces: ['public_mcp'] }),
          makeToolItem({ name: 'masc_start', surfaces: ['public_mcp'] }),
          makeToolItem({ name: 'internal_only', surfaces: ['internal'] }),
        ],
      },
    })

    render(html`<${SettingsSurface} />`, container)

    const mcpNav = container.querySelector('[data-testid="settings-nav-mcp"]') as HTMLElement
    await fireEvent.click(mcpNav)

    await waitFor(() => {
      const labels = Array.from(container.querySelectorAll('.set-row .mono')).map(n => n.textContent)
      expect(labels).toContain('masc_handoff')
      expect(labels).toContain('masc_start')
      // internal-only tools are not exposed over public MCP.
      expect(labels).not.toContain('internal_only')
    })
    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('live inventory + local controls')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-settings-mode')).toBe('local')
  })

  it('MCP exposed-tool toggles are clickable local controls', async () => {
    apiMock.fetchDashboardTools.mockResolvedValue({
      tool_inventory: {
        count: 2,
        tools: [
          makeToolItem({ name: 'masc_handoff', surfaces: ['public_mcp'] }),
          makeToolItem({ name: 'masc_start', surfaces: ['public_mcp'] }),
        ],
      },
    })

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-mcp"]') as HTMLElement)
    await waitFor(() => {
      expect(container.textContent).toContain('Exposed tools (2/2)')
    })

    const toggles = Array.from(container.querySelectorAll<HTMLButtonElement>('[data-testid="set-toggle"]'))
    expect(toggles.length).toBe(2)
    expect(toggles[0]!.disabled).toBe(false)
    expect(toggles[0]!.getAttribute('aria-checked')).toBe('true')

    await fireEvent.click(toggles[0]!)

    expect(toggles[0]!.getAttribute('aria-checked')).toBe('false')
    expect(container.textContent).toContain('Exposed tools (1/2)')
  })

  it('renders the fusion preset section (panel families + judge) read-only', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-fusion"]') as HTMLElement)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('패널·심판 심의')
    // trio preset lanes: 3 panel models + 1 judge, with prototype labels.
    const lanes = container.querySelectorAll('.set-fus-lane')
    expect(lanes.length).toBe(2)
    const models = Array.from(container.querySelectorAll('.set-fus-model')).map(n => n.textContent)
    expect(models).toContain('ollama_cloud.deepseek-v4-flash')
    expect(models).toContain('glm-coding.glm-5-turbo')
    expect(models).toContain('ollama_cloud.minimax-m3')
    expect(container.querySelector('.set-fus-model.judge')?.textContent).toBe('deepseek.deepseek-v4-pro')
    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('local preview only')
    expect((container.querySelector('[data-testid="set-toggle"]') as HTMLButtonElement).disabled).toBe(false)
    expect(container.querySelector('[data-testid="fusion-settings-editor"]')).toBeNull()
    expect(container.textContent).not.toContain('per_hour_budget')
  })

  it('renders the live fusion settings writer only behind VITE_FUSION_SETTINGS_WRITABLE', async () => {
    vi.stubEnv('VITE_FUSION_SETTINGS_WRITABLE', 'true')
    const fetchMock = vi.fn(async (url: RequestInfo | URL) => {
      const path = String(url)
      if (path === '/api/v1/runtime/config/raw') {
        return new Response(JSON.stringify({
          ok: true,
          path: MOCK_RUNTIME_PATH,
          file_name: 'runtime.toml',
          source_text: '[fusion]\nenabled = true\ndefault_preset = "trio"\nmax_concurrent_panels = 2\n\n[fusion.presets.trio]\nmin_answered = 2\n',
          reloaded: false,
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ message: `unexpected ${path}` }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', fetchMock)
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-fusion"]') as HTMLElement)

    await waitFor(() => expect(container.querySelector('[data-testid="fusion-settings-editor"]')).not.toBeNull())
    expect(fetchMock).toHaveBeenCalledWith('/api/v1/runtime/config/raw', expect.any(Object))
    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml live-backed')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.querySelectorAll('.set-fus-lane').length).toBe(0)
    expect(container.textContent).not.toContain('ollama_cloud.deepseek-v4-flash')
  })

  it('renders the tool-group policy with exec-guard and last_turn_safe', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-policy"]') as HTMLElement)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('도구 정책')
    // 11 named groups in the prototype snapshot.
    expect(container.querySelectorAll('[data-testid="set-tg-row"]').length).toBe(11)
    expect(container.textContent).toContain('browser-session grant preview')
    expect(container.textContent).toContain('현재는 live tool-policy writer가 없어 prototype group catalog 스냅샷으로 표시합니다.')
    expect(container.textContent).not.toContain('기본 부여 그룹과 안전장치를 관리합니다')
    expect(container.querySelector('[data-testid="policy-local-summary"]')?.textContent).toContain('10/11 enabled')
    expect(container.querySelectorAll('[data-testid="settings-preview-badge"]').length).toBeGreaterThanOrEqual(12)
    // execute group carries the 3-layer guard badge; voice is opt-in.
    const kinds = Array.from(container.querySelectorAll('.set-tg-kind')).map(n => n.textContent?.trim())
    expect(kinds).toContain('3-layer guard')
    expect(kinds).toContain('opt-in')
    const firstToggle = container.querySelector('[data-testid="set-tg-row"] [data-testid="set-toggle"]') as HTMLButtonElement
    expect(firstToggle.getAttribute('data-active')).toBe('true')
    await fireEvent.click(firstToggle)
    expect(firstToggle.getAttribute('data-active')).toBe('false')
    expect(container.querySelector('[data-testid="policy-local-summary"]')?.textContent).toContain('9/11 enabled')
    expect(sessionStorage.getItem('masc.settings.local.policyGrant')).toContain('"base":false')

    render(null, container)
    route.value = { tab: 'settings', params: {}, postId: null }
    render(html`<${SettingsSurface} />`, container)
    await fireEvent.click(container.querySelector('[data-testid="settings-nav-policy"]') as HTMLElement)

    expect(container.querySelector('[data-testid="policy-local-summary"]')?.textContent).toContain('9/11 enabled')
    expect(
      container.querySelector('[data-testid="set-tg-row"] [data-testid="set-toggle"]')?.getAttribute('data-active'),
    ).toBe('false')
    // exec-guard pipeline: validate_command → destructive_guard → write_gate.
    const guardSteps = Array.from(
      container.querySelectorAll('[data-testid="set-guard"] .set-guard-step'),
    ).map(n => n.textContent)
    expect(guardSteps).toEqual(['validate_command', 'destructive_guard', 'write_gate'])
    expect(container.querySelectorAll('[data-testid="set-guard"] .set-guard-arrow').length).toBe(2)
    // last_turn_safe chips carry the .safe modifier.
    expect(container.querySelectorAll('.set-tg-chip.safe').length).toBeGreaterThan(0)
  })

  it('shows the Discord trigger policy as live connector data without preview radios', async () => {
    gateApiMock.fetchGateConnectors.mockResolvedValue(makeGateConnectors({
      connectors: [],
      total: 0,
      active_count: 0,
      discord_trigger_policy: 'mention_only',
    }))
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-gate"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-gate-discord-trigger"]')?.textContent).toBe('mention_only')
      expect(container.querySelector('[data-testid="settings-gate-empty"]')).not.toBeNull()
    })
    expect(container.querySelector('[data-testid="set-trigger"]')).toBeNull()
  })

  it('opens the live runtime.toml editor from runtime management', async () => {
    const runtimeConfig = {
      ok: true,
      path: MOCK_RUNTIME_PATH,
      file_name: 'runtime.toml',
      source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
      reloaded: false,
    }
    const fetchMock = vi.fn(async (input: unknown) => {
      const requestUrl =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.href
            : typeof (input as { url?: unknown }).url === 'string'
              ? (input as { url: string }).url
              : ''
      const path = requestUrl.startsWith('http')
        ? new URL(requestUrl).pathname
        : requestUrl.split('?')[0] ?? requestUrl
      if (path === '/api/v1/dashboard/dev-token') {
        return new Response(JSON.stringify({ token: 'dev-token', actor: 'dashboard' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (path === '/api/v1/runtime/config/raw') {
        return new Response(JSON.stringify(runtimeConfig), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ message: `unexpected ${path}` }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-runtimes"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('런타임 관리')
      expect(container.querySelector('[data-testid="runtime-toml-editor"]')).not.toBeNull()
      expect(container.querySelector('.rt-overlay')).toBeNull()
      expect(container.textContent).toContain(MOCK_RUNTIME_PATH)
    })

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/runtime/config/raw',
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer dev-token' }),
      }),
    )
  })
})

describe('SettingsSurface shell route', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMock.fetchLogs.mockReset()
    apiMock.fetchDashboardTools.mockReset()
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeProviders.mockReset()
    apiMock.fetchKeeperConfig.mockReset()
    apiMock.patchKeeperConfig.mockReset()
    gateApiMock.fetchGateConnectors.mockReset()
    keeperApiMock.fetchKeepersComposite.mockReset()
    stubEmptyApi()
    keepers.value = [makeKeeper()]
    dashboardLoading.value = false
    connected.value = true
    namespaceTruthInitializing.value = false
    document.title = 'MASC Dashboard'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    keepers.value = []
  })

  it('renders from the dashboard shell route', async () => {
    route.value = { tab: 'settings', params: {}, postId: null }

    render(html`<${DashboardMain} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-surface"]')).not.toBeNull()
    })
    await waitFor(() => {
      expect(document.title).toBe('MASC · Settings')
    })
  })
})

describe('settings read-surface helpers', () => {
  it('checks Settings path preview values by format only', () => {
    expect(checkSettingsMcpEndpoint('https://masc.local/mcp')).toEqual({
      ok: true,
      message: 'valid MCP URL',
    })
    expect(checkSettingsMcpEndpoint('ftp://masc.local/mcp')).toEqual({
      ok: false,
      message: 'expected http(s) URL',
    })
    expect(checkSettingsMcpEndpoint('https://masc.local/api')).toEqual({
      ok: false,
      message: 'path should include /mcp',
    })

    expect(checkSettingsStoreUrl('postgres://masc.local:5432/masc')).toEqual({
      ok: true,
      message: 'valid store URL',
    })
    expect(checkSettingsStoreUrl('https://masc.local/db')).toEqual({
      ok: false,
      message: 'expected postgres URL',
    })

    expect(checkSettingsWorktreeBase('~/wt')).toEqual({
      ok: true,
      message: 'valid local path',
    })
    expect(checkSettingsWorktreeBase('http://masc.local/wt')).toEqual({
      ok: false,
      message: 'expected filesystem path',
    })
  })

  it('mcpExposedToolNames keeps only public_mcp tools, sorted', () => {
    const names = mcpExposedToolNames([
      makeToolItem({ name: 'masc_start', surfaces: ['public_mcp'] }),
      makeToolItem({ name: 'masc_handoff', surfaces: ['public_mcp', 'keeper'] }),
      makeToolItem({ name: 'internal_only', surfaces: ['internal'] }),
      makeToolItem({ name: 'no_surface', surfaces: [] }),
    ])
    expect(names).toEqual(['masc_handoff', 'masc_start'])
  })

  it('mcpExposedToolNames returns [] for empty inventory (no fabrication)', () => {
    expect(mcpExposedToolNames([])).toEqual([])
  })

  it('logRowStatus derives status from level only', () => {
    expect(logRowStatus('ERROR')).toBe('fail')
    expect(logRowStatus('error')).toBe('fail')
    expect(logRowStatus('WARN')).toBe('warn')
    expect(logRowStatus('INFO')).toBe('ok')
    expect(logRowStatus('DEBUG')).toBe('ok')
  })

  it('logEntryToSysRow maps a ring entry to [time, level, identity, message, status]', () => {
    const row = logEntryToSysRow(
      makeLogEntry({
        ts: '2026-06-21T16:24:51Z',
        level: 'ERROR',
        keeper_name: 'drifter',
        module: 'Keeper',
        message: 'masc_trace_window 실패',
      }),
    )
    expect(row).toEqual(['16:24:51', 'error', 'drifter', 'masc_trace_window 실패', 'fail'])
  })

  it('logEntryToSysRow falls back to module then (root) for identity', () => {
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: 'Server' }))[2]).toBe('Server')
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: '' }))[2]).toBe('(root)')
  })
})
