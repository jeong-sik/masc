// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import {
  SettingsSurface,
  mcpExposedToolNames,
  logEntryToSysRow,
  logRowStatus,
  normalizeSettingsSection,
} from './settings-surface'
import type {
  ConfigEntry,
  DashboardConfigResponse,
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  LogEntry,
  RuntimeDefaultsResponse,
} from '../api/dashboard'
import { DashboardMain } from './dashboard-shell'
import { route } from '../router'
import { connected } from '../sse'
import { tweaksDensity } from './tweaks-panel'

const MOCK_RUNTIME_PATH = 'fixture/config/runtime.toml'
import { dashboardLoading, shellConfigResolution, shellRuntimeResolution } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'
import { resetDevTokenBootstrap } from '../api/dev-token'

const apiMock = vi.hoisted(() => ({
  fetchDashboardConfig: vi.fn(),
  fetchLogs: vi.fn(),
  fetchDashboardTools: vi.fn(),
  fetchRuntimeDefaults: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
  fetchRuntimeTomlConfig: vi.fn(),
  patchRuntimeMediaFailover: vi.fn(),
  patchRuntimeRouting: vi.fn(),
  saveRuntimeTomlConfig: vi.fn(),
}))

const mcpMock = vi.hoisted(() => ({
  callMcpTool: vi.fn(async () => 'namespace ok'),
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

const runtimeRefreshMock = vi.hoisted(() => ({
  refreshRuntimeConfigConsumers: vi.fn(async () => undefined),
}))

vi.mock('../api/dashboard.js', async () => {
  const actual = await vi.importActual<typeof import('../api/dashboard')>('../api/dashboard')
  return {
    ...actual,
    fetchDashboardConfig: apiMock.fetchDashboardConfig,
    fetchLogs: apiMock.fetchLogs,
    fetchDashboardTools: apiMock.fetchDashboardTools,
    fetchRuntimeDefaults: apiMock.fetchRuntimeDefaults,
    fetchRuntimeProviders: apiMock.fetchRuntimeProviders,
    fetchRuntimeTomlConfig: apiMock.fetchRuntimeTomlConfig,
    patchRuntimeMediaFailover: apiMock.patchRuntimeMediaFailover,
    patchRuntimeRouting: apiMock.patchRuntimeRouting,
    saveRuntimeTomlConfig: apiMock.saveRuntimeTomlConfig,
  }
})

vi.mock('../lib/runtime-config-refresh', () => ({
  refreshRuntimeConfigConsumers: runtimeRefreshMock.refreshRuntimeConfigConsumers,
}))

vi.mock('../api/mcp', () => ({
  callMcpTool: mcpMock.callMcpTool,
}))

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
      structured_judge_runtime_id: null,
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

function makeConfigEntry(overrides: Partial<ConfigEntry> = {}): ConfigEntry {
  return {
    env: 'MASC_BASE_PATH',
    description: 'Base storage directory',
    value: null,
    default: '(cwd)',
    source: 'runtime',
    source_detail: 'resolved from runtime',
    provenance: {
      kind: 'runtime',
      detail: 'resolved from runtime',
    },
    sensitive: false,
    ...overrides,
  }
}

function makeDashboardConfig(overrides: Partial<DashboardConfigResponse> = {}): DashboardConfigResponse {
  return {
    generated_at: '2026-06-21T00:00:00Z',
    server: {
      version: 'test',
      git_commit: null,
      ocaml_version: '5.4.0',
      uptime_seconds: 12,
      pid: 123,
    },
    categories: {
      server: [
        makeConfigEntry({ env: 'MASC_URL', description: 'MCP URL', value: 'http://127.0.0.1:8935/mcp', default: '(derived)', source: 'env', source_detail: 'environment variable MASC_URL' }),
        makeConfigEntry({ env: 'MASC_HTTP_BASE_URL', description: 'HTTP base URL', value: 'http://127.0.0.1:8935', default: '(derived)', source: 'env', source_detail: 'environment variable MASC_HTTP_BASE_URL' }),
        makeConfigEntry({ env: 'MASC_BASE_PATH', description: 'Base storage directory', value: '/workspace', default: '(cwd)', source: 'env', source_detail: 'environment variable MASC_BASE_PATH' }),
      ],
      path: [
        makeConfigEntry({ env: 'MASC_CONFIG_DIR', description: 'Config directory override', value: null, default: '(none)', source: 'default', source_detail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DATA_DIR', description: 'Data directory override', value: null, default: '(none)', source: 'default', source_detail: 'compiled default value' }),
      ],
      dashboard: [
        makeConfigEntry({ env: 'MASC_DASHBOARD_CTX_PREPARING', description: 'Context preparing', value: '0.70', default: '0.70', source: 'default', source_detail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_CTX_HANDOFF_IMMINENT', description: 'Context imminent', value: '0.85', default: '0.85', source: 'default', source_detail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO', description: 'Runtime warning', value: '0.95', default: '0.95', source: 'default', source_detail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_SIGNAL_STALE_SEC', description: 'Signal stale', value: '1200.0', default: '1200.0', source: 'default', source_detail: 'compiled default value' }),
      ],
      alerting: [
        makeConfigEntry({ env: 'MASC_ALERT_DEDUP_WINDOW_SEC', description: 'Alert dedup', value: '60.0', default: '60.0', source: 'default', source_detail: 'compiled default value' }),
      ],
    },
    ...overrides,
  }
}

function stubRuntimeDefaults(value: RuntimeDefaultsResponse = makeRuntimeDefaults()) {
  apiMock.fetchRuntimeDefaults.mockResolvedValue(value)
}

function stubEmptyApi() {
  apiMock.fetchDashboardConfig.mockResolvedValue(makeDashboardConfig())
  apiMock.fetchLogs.mockResolvedValue({ total: 0, entries: [] })
  apiMock.fetchDashboardTools.mockResolvedValue({ tool_inventory: { count: 0, tools: [] } })
  stubRuntimeDefaults()
  apiMock.fetchRuntimeProviders.mockResolvedValue(makeRuntimeProviders())
  apiMock.fetchRuntimeTomlConfig.mockResolvedValue({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    reloaded: false,
  })
  apiMock.patchRuntimeMediaFailover.mockImplementation(async () => ({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    reloaded: true,
  }))
  apiMock.patchRuntimeRouting.mockImplementation(async () => ({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    reloaded: true,
  }))
  apiMock.saveRuntimeTomlConfig.mockImplementation(async (sourceText: string) => ({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: sourceText,
    reloaded: true,
  }))
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
    apiMock.fetchDashboardConfig.mockReset()
    apiMock.fetchLogs.mockReset()
    apiMock.fetchDashboardTools.mockReset()
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeProviders.mockReset()
    apiMock.fetchRuntimeTomlConfig.mockReset()
    apiMock.patchRuntimeMediaFailover.mockReset()
    apiMock.patchRuntimeRouting.mockReset()
    apiMock.saveRuntimeTomlConfig.mockReset()
    runtimeRefreshMock.refreshRuntimeConfigConsumers.mockClear()
    mcpMock.callMcpTool.mockClear()
    promptApiMock.clearPromptOverride.mockClear()
    promptApiMock.fetchDashboardPrompts.mockClear()
    promptApiMock.savePromptOverride.mockClear()
    stubEmptyApi()
    shellRuntimeResolution.value = {
      generated_at: '2026-06-21T00:00:00Z',
      status: 'ready',
      warnings: [],
      base_path: { path: '/workspace', exists: true, source: 'MASC_BASE_PATH' },
      workspace_path: { path: '/workspace', exists: true, source: 'workspace' },
      resolved_base_path: { path: '/workspace/.masc', exists: true, source: 'runtime' },
      data_root: { path: '/workspace/.masc/data', exists: true, source: 'derived' },
      prompt_markdown_dir: { path: '/workspace/.masc/prompts', exists: true, source: 'derived' },
      server_repo_path: null,
      server_repo_git_commit: null,
      workspace_git_commit: null,
      resolved_base_git_commit: null,
      source_mismatch: false,
      server_workspace_mismatch: false,
      diagnostics: [],
      build: {
        release_version: 'test',
        commit: null,
        started_at: '2026-06-21T00:00:00Z',
        uptime_seconds: 12,
      },
      keeper_runtime: null,
      fleet_safety: null,
      fd_accountant: null,
      cdal: null,
    }
    shellConfigResolution.value = {
      status: 'ready',
      warnings: [],
      config_root: { path: '/workspace/.masc/config', exists: true, source: 'derived' },
      runtime_authoring: { path: '/workspace/.masc/config/runtime.toml', exists: true, source: 'derived' },
      runtime: { path: MOCK_RUNTIME_PATH, exists: true, source: 'runtime.toml' },
      prompts: { path: '/workspace/.masc/config/prompts', exists: true, source: 'derived' },
      keepers: { path: '/workspace/.masc/keepers', exists: true, source: 'derived' },
      personas: { path: '/workspace/.masc/personas', exists: true, source: 'derived' },
    }
    localStorage.clear()
    tweaksDensity.value = 'spacious'
    window.location.hash = '#settings'
    route.value = { tab: 'settings', params: {}, postId: null }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    navigate.mockClear()
    shellConfigResolution.value = null
    shellRuntimeResolution.value = null
    resetDevTokenBootstrap()
    sessionStorage.clear()
    localStorage.clear()
    tweaksDensity.value = 'spacious'
    vi.unstubAllGlobals()
    vi.unstubAllEnvs()
  })

  it('renders the surface and category navigation', () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('.v2-shell-surface')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-surface"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-runtime"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-runtimes"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-paths"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-mcp"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-notify"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-logs"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-account"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-policy"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-gate"]')).toBeNull()
  })

  it('applies StyleSeed surface and card classes', () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('.v2-shell-surface.ss-surface.bg-surface-page.text-text-primary')).not.toBeNull()
    expect(container.querySelector('.set-card-b.set-card-b-wide')).not.toBeNull()
  })

  it('switches sections when category navigation is clicked', async () => {
    render(html`<${SettingsSurface} />`, container)

    const title = () => container.querySelector('[data-testid="settings-section-title"]') as HTMLElement
    expect(title().textContent).toBe('런타임')

    const pathsNav = container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement
    await fireEvent.click(pathsNav)

    expect(title().textContent).toBe('경로 · Path')
    expect(pathsNav.getAttribute('data-active')).toBe('true')
    expect(navigate).toHaveBeenLastCalledWith('settings', { section: 'paths' })

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    expect(title().textContent).toBe('런타임')
    expect(navigate).toHaveBeenLastCalledWith('settings', {})
  })

  it('selects a valid section from the dashboard route', () => {
    route.value = { tab: 'settings', params: { section: 'logs' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('관측 · 시스템 로그')
    expect(container.querySelector('[data-testid="settings-nav-logs"]')?.getAttribute('data-active')).toBe('true')
    expect(container.querySelector('[data-testid="log-viewer"]')).not.toBeNull()
  })

  it('renders a live theme switch inside the display section that can reach Paper', async () => {
    route.value = { tab: 'settings', params: { section: 'display' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('표시')
    const themeButton = [...container.querySelectorAll('button')]
      .find(b => /DARK|STYLESEED|PAPER/.test(b.textContent ?? ''))
    expect(themeButton).toBeTruthy()

    await fireEvent.click(themeButton as HTMLButtonElement)
    expect(document.documentElement.dataset.theme).toBe('styleseed')

    await fireEvent.click(themeButton as HTMLButtonElement)
    expect(document.documentElement.dataset.theme).toBe('paper')
    expect(localStorage.getItem('dashboardTheme')).toBe('paper')
  })

  it('wires display density to the dashboard density signal without fake locale previews', async () => {
    route.value = { tab: 'settings', params: { section: 'display' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent)
      .toContain('theme/density live')
    expect(container.querySelector('[data-testid="display-live-summary"]')?.textContent)
      .toContain('spacious')

    const clickSeg = async (label: string) => {
      const button = Array.from(container.querySelectorAll<HTMLButtonElement>('.set-seg-b'))
        .find(candidate => candidate.textContent === label)
      expect(button).toBeTruthy()
      await fireEvent.click(button as HTMLButtonElement)
    }

    await clickSeg('compact')

    expect(tweaksDensity.value).toBe('compact')
    expect(container.querySelector('[data-testid="display-live-summary"]')?.textContent)
      .toContain('compact')
    expect(container.querySelector('[data-testid="display-locale-readonly"]')?.textContent)
      .toContain('no writer')
    expect(container.querySelector('[data-testid="set-toggle"]')).toBeNull()
    expect([...container.querySelectorAll('.set-seg-b')].map(b => b.textContent))
      .toEqual(['compact', 'regular', 'spacious'])
    expect(sessionStorage.getItem('masc.settings.local.displayLocale')).toBeNull()
    expect(sessionStorage.getItem('masc.settings.local.displayTimezone')).toBeNull()
    expect(sessionStorage.getItem('masc.settings.local.displayClock24')).toBeNull()

    render(null, container)
    render(html`<${SettingsSurface} />`, container)

    expect(tweaksDensity.value).toBe('compact')
    expect(container.querySelector('[data-testid="display-live-summary"]')?.textContent)
      .toContain('compact')
  })

  it('falls invalid settings sections back to runtime without a fake subsection', () => {
    expect(normalizeSettingsSection('not-real')).toBe('runtime')
    route.value = { tab: 'settings', params: { section: 'not-real' }, postId: null }

    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('런타임')
    expect(container.querySelector('[data-testid="settings-nav-runtime"]')?.getAttribute('data-active')).toBe('true')
  })

  it('syncs when the dashboard route section changes while mounted', async () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('런타임')

    route.value = { tab: 'settings', params: { section: 'logs' }, postId: null }

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('관측 · 시스템 로그')
    })
  })

  it('does not render removed fake-only settings sections', async () => {
    render(html`<${SettingsSurface} />`, container)

    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml + provider catalog')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-settings-mode')).toBe('live')
    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.textContent).not.toContain('Save changes')
    expect(container.textContent).not.toContain('Reissue')
    expect(container.textContent).not.toContain('Log out')
    expect(container.querySelector('[data-testid="settings-nav-account"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-policy"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-sandbox"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-gate"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-ide"]')).toBeNull()
  })

  it('MCP server page shows resolved endpoint, inventory, and runs a real status check', async () => {
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
    mcpMock.callMcpTool.mockResolvedValueOnce('status ok from mcp')

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-mcp"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-mcp-endpoint"]')?.textContent).toBe('http://127.0.0.1:8935/mcp')
      expect(container.querySelector('[data-testid="mcp-tools-list"]')?.textContent).toContain('masc_handoff')
      expect(container.querySelector('[data-testid="mcp-tools-list"]')?.textContent).not.toContain('internal_only')
    })

    await fireEvent.click(container.querySelector('[data-testid="settings-mcp-check"]') as HTMLElement)

    await waitFor(() => {
      expect(mcpMock.callMcpTool).toHaveBeenCalledWith('masc_status', {})
      expect(container.querySelector('[data-testid="settings-mcp-check-result"]')?.textContent).toContain('status ok from mcp')
    })
  })

  it('MCP server page surfaces inventory load failures instead of fabricating an empty tool list', async () => {
    apiMock.fetchDashboardTools.mockRejectedValueOnce(new Error('inventory offline'))
    mcpMock.callMcpTool.mockResolvedValueOnce('status ok despite inventory failure')

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-mcp"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="mcp-tools-error"]')?.textContent)
        .toContain('inventory offline')
    })
    expect(container.querySelector('[data-testid="mcp-tools-empty"]')).toBeNull()
    expect(container.querySelector('[data-testid="mcp-tools-list"]')).toBeNull()
    expect(container.textContent).toContain('Exposed public MCP tools (—)')

    await fireEvent.click(container.querySelector('[data-testid="settings-mcp-check"]') as HTMLElement)

    await waitFor(() => {
      expect(mcpMock.callMcpTool).toHaveBeenCalledWith('masc_status', {})
      expect(container.querySelector('[data-testid="settings-mcp-check-result"]')?.textContent)
        .toContain('status ok despite inventory failure')
    })
  })

  it('paths page shows resolved server paths instead of editable local previews', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)

    await waitFor(() => {
      expect(container.textContent).toContain('/workspace/.masc')
      expect(container.textContent).toContain(MOCK_RUNTIME_PATH)
      expect(container.textContent).toContain('MASC_BASE_PATH')
    })
    expect(container.textContent).not.toContain('format-checked only')
    expect(container.querySelector('[data-testid="settings-store-url-input"]')).toBeNull()
    expect(container.querySelector('[data-testid="settings-worktree-base-input"]')).toBeNull()
  })

  it('paths page does not fabricate unknown rows when path resolution is unavailable', async () => {
    shellRuntimeResolution.value = null
    shellConfigResolution.value = null
    apiMock.fetchDashboardConfig.mockRejectedValueOnce(new Error('config unavailable'))
    stubRuntimeDefaults(makeRuntimeDefaults({ config_path: null }))
    apiMock.fetchRuntimeProviders.mockResolvedValueOnce(makeRuntimeProviders({ config_path: null }))

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('path resolution unavailable')
      expect(container.querySelector('[data-testid="settings-path-resolution-error"]')?.textContent).toContain('추정값으로 표시하지 않습니다')
    })
    expect(container.textContent).not.toContain('미수집')
    expect(container.textContent).not.toContain('Runtime path resolution')
    expect(container.textContent).not.toContain('Config env inputs')
  })

  it('paths page labels provider-only path data as partial resolution', async () => {
    shellRuntimeResolution.value = null
    shellConfigResolution.value = null
    apiMock.fetchDashboardConfig.mockRejectedValueOnce(new Error('config unavailable'))

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('partial path resolution')
      expect(container.querySelector('[data-testid="settings-runtime-path-resolution-missing"]')?.textContent).toContain('확인 가능한 값만 표시합니다')
      expect(container.textContent).toContain('/cfg/runtime.toml')
    })
    expect(container.querySelector('[data-testid="settings-config-error"]')?.textContent).toContain('dashboard config projection')
    expect(container.textContent).not.toContain('MASC_BASE_PATH')
    expect(container.textContent).not.toContain('미수집')
  })

  it('notify page shows live thresholds without fake local routing controls', async () => {
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-notify"]') as HTMLElement)

    await waitFor(() => {
      expect(container.textContent).toContain('MASC_DASHBOARD_CTX_PREPARING')
      expect(container.textContent).toContain('70%')
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('live thresholds read-only')
      expect(container.querySelector('[data-testid="notify-routing-readonly"]')?.textContent).toContain('no writer')
    })

    expect(container.querySelector('[data-testid="notify-local-summary"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-slider"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-stepper"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-toggle"]')).toBeNull()
    expect(container.querySelector('[data-testid="set-seg"]')).toBeNull()
    expect(sessionStorage.getItem('masc.settings.local.notifyChannel')).toBeNull()
  })

  it('notify page surfaces config projection failures instead of rendering missing thresholds', async () => {
    apiMock.fetchDashboardConfig.mockRejectedValueOnce(new Error('config projection offline'))

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-notify"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="notify-config-error"]')?.textContent)
        .toContain('config projection offline')
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent)
        .toContain('config unavailable')
    })

    expect(container.querySelector('[data-testid="notify-thresholds"]')).toBeNull()
    expect(container.textContent).not.toContain('MASC_DASHBOARD_CTX_PREPARING')
    expect(container.querySelector('[data-testid="notify-routing-readonly"]')).toBeNull()
  })

  it('renders runtime settings as a live-backed entry point instead of fake local controls', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml + provider catalog')
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
    apiMock.fetchRuntimeProviders.mockResolvedValue(makeRuntimeProviders({
      providers: [
        makeRuntimeProvider({
          parameter_policy: {
            reasoning_toggle_wire: 'chat-template-kwargs',
            reasoning_replay_policy: 'preserve-always',
            requires_reasoning_replay_on_tool_call: true,
            ignored_sampling_params: ['temperature'],
            always_ignored_sampling_params: ['top_p'],
          },
          request_config: {
            source: 'oas-provider-config',
            provider_kind: 'openai_compat',
            request_path: '/chat/completions',
            request_path_targets_responses_api: false,
            max_tokens: 4096,
            max_context: 131072,
            temperature: null,
            top_p: null,
            top_k: 40,
            min_p: 0.05,
            has_system_prompt: true,
            enable_thinking: true,
            preserve_thinking: true,
            thinking_budget: 8192,
            clear_thinking: false,
            resolved_reasoning_effort: 'high',
            glm_clear_thinking: false,
            glm_replay_reasoning: false,
            tool_stream: true,
            tool_choice: { kind: 'required' },
            disable_parallel_tool_use: true,
            response_format: { kind: 'json_schema', has_schema: true },
            has_output_schema: true,
            cache_system_prompt: true,
            supports_tool_choice_override: true,
            supports_structured_output_override: true,
            has_model_capabilities_override: true,
            keep_alive: '30m',
            internal_model_rotation_count: 2,
            num_ctx: 131072,
            seed: 42,
            has_previous_response_id: true,
            connect_timeout_s: 120,
          },
          effective_capabilities: {
            source: 'oas-provider-config-model',
            max_output_tokens: 4096,
            supports_tool_choice: true,
            supports_parallel_tool_calls: true,
            supports_runtime_mcp_tools: true,
            supports_runtime_tool_events: true,
            assistant_tool_content_format: 'empty-string',
            supports_response_format_json: true,
            supports_structured_output: true,
            supports_reasoning: true,
            accepted_reasoning_efforts: null,
            preserve_thinking_control_format: 'always-preserved',
            reasoning_output_format: 'split-reasoning-fields',
            reasoning_streaming_format: {
              kind: 'delta-reasoning-field',
              field: 'reasoning_content',
            },
            reasoning_replay_override: 'preserve-always',
            supports_system_prompt: true,
            supports_caching: true,
            supports_prompt_caching: true,
            prompt_cache_alignment: 1024,
            supports_top_k: true,
            supports_min_p: true,
            supports_seed: true,
            supports_seed_with_images: true,
            supports_code_execution: true,
            emits_usage_tokens: true,
            modality_priority: 'visual-first',
            task: 'transcription',
            supported_models: ['m1'],
          },
          declared_spec: {
            source: 'runtime.toml',
            provider: {
              id: 'provider-a',
              display_name: 'Provider A',
              protocol: 'openai-compatible-http',
              api_format: 'chat-completions',
              transport: 'http',
              auth_kind: 'env:RUNPOD_API_KEY',
              is_non_interactive: true,
              has_capabilities: true,
              behavior_capabilities: {
                supports_inline_tools: true,
                requires_per_keeper_bridging_for_bound_actor_tools: true,
                identity_runtime_mcp_header_keys: ['x-masc-keeper'],
                argv_prompt_preflight: true,
                uses_anthropic_caching: true,
                max_turns_per_attempt: 3,
                tolerates_bound_actor_fallback: true,
              },
              custom_header_count: 1,
              connect_timeout_s: 120,
            },
            model: {
              id: 'm1',
              api_name: 'm1',
              tools_support: true,
              max_context: 131072,
              thinking_support: true,
              preserve_thinking: true,
              max_thinking_budget: 8192,
              streaming: true,
              temperature: 0.65,
              capabilities: {
                source: 'runtime.toml',
                max_output_tokens: 4096,
                supports_tool_choice: true,
                supports_required_tool_choice: true,
                supports_named_tool_choice: true,
                supports_parallel_tool_calls: true,
                supports_extended_thinking: true,
                supports_reasoning_budget: true,
                thinking_control_format: 'chat-template-kwargs',
                supports_image_input: true,
                supports_audio_input: false,
                supports_video_input: false,
                supports_multimodal_inputs: true,
                supports_response_format_json: true,
                supports_structured_output: true,
                supports_native_streaming: true,
                supports_system_prompt: true,
                supports_caching: true,
                supports_prompt_caching: true,
                prompt_cache_alignment: 1024,
                supports_top_k: true,
                supports_min_p: true,
                supports_seed: true,
                supports_seed_with_images: true,
                emits_usage_tokens: true,
                supports_computer_use: false,
                supports_code_execution: true,
              },
              match_prefixes: ['m1'],
            },
            binding: {
              provider_id: 'provider-a',
              model_id: 'm1',
              is_default: true,
              max_concurrent: 4,
              price_input: 0.1,
              price_output: 0.2,
              keep_alive: '30m',
              num_ctx: 131072,
            },
          },
        }),
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
    }))

    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      expect((container.querySelector('[data-testid="runtime-default-runtime"]') as HTMLSelectElement | null)?.value).toBe('rt-a')
      expect(container.querySelector('[data-testid="runtime-default-model"]')?.textContent).toBe('m1')
      expect(container.querySelector('[data-testid="runtime-settings-config-path"]')?.textContent).toContain('/cfg/runtime.toml')
      const cards = Array.from(container.querySelectorAll('[data-testid="runtime-catalog-card"]'))
      expect(cards.length).toBe(2)
      expect(cards.map(card => card.textContent)).toEqual([
        expect.stringContaining('Provider A'),
        expect.stringContaining('Provider B'),
      ])
      expect(cards[0]?.textContent).toContain('wire:chat-template-kwargs')
      expect(cards[0]?.textContent).toContain('sampling:top_k:40,min_p:0.05')
      expect(cards[0]?.textContent).toContain('tool:required')
      expect(cards[0]?.textContent).toContain('modality:visual-first')
      expect(cards[0]?.textContent).toContain('tool-content:empty-string')
      expect(cards[0]?.textContent).toContain('preserve:always-preserved')
      expect(cards[0]?.textContent).toContain('task:transcription')
      expect(cards[0]?.textContent).toContain('declared:api:chat-completions')
      expect(cards[0]?.textContent).toContain('transport:http')
      expect(cards[0]?.textContent).toContain('headers:1')
      expect(cards[0]?.textContent).toContain('temp:0.65')
      expect(cards[0]?.textContent).toContain('budget:8192')
      expect(cards[0]?.textContent).toContain(
        'controls:tool-choice,required,named,parallel,native-stream,system-prompt,cache,prompt-cache@1024,seed+images,usage,code-exec',
      )
      expect(cards[0]?.textContent).toContain('behavior:inline-tools,keeper-bridge')
      expect(container.querySelector('[data-testid="runtime-catalog-default"]')?.textContent).toBe('default')
      expect(
        Array.from(container.querySelectorAll('[data-runtime-section]'))
          .map(section => section.getAttribute('data-runtime-section')),
        // routing/assignments 서브섹션은 전용 Routing 섹션으로 이동했다.
      ).toEqual(['catalog'])
    })
    expect(container.textContent).not.toContain('oas·seoul-1')
  })

  it('runtime overview falls back to runtime-defaults when the rich provider catalog is unavailable', async () => {
    apiMock.fetchRuntimeProviders.mockRejectedValueOnce(new Error('provider catalog unavailable'))

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-catalog-fallback"]')?.textContent)
        .toContain('runtime defaults')
      const cards = Array.from(container.querySelectorAll('[data-testid="runtime-catalog-card"]'))
      expect(cards.length).toBe(3)
      expect(cards.map(card => card.textContent)).toEqual([
        expect.stringContaining('rt-a'),
        expect.stringContaining('rt-b'),
        expect.stringContaining('rt-c'),
      ])
      expect(cards[0]?.textContent).toContain('P')
      expect(cards[0]?.textContent).toContain('m1')
      expect(cards[0]?.textContent).toContain('128K ctx')
      expect(cards[0]?.textContent).toContain('? tools')
      expect(cards[0]?.textContent).toContain('? thinking')
      expect(cards[0]?.textContent).toContain('? streaming')
    })
    expect(container.querySelector('[data-testid="runtime-catalog-error"]')).toBeNull()
  })

  it('runtime overview does not show the fallback warning while provider catalog is still loading', async () => {
    apiMock.fetchRuntimeProviders.mockReturnValueOnce(new Promise(() => {}))

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement)

    await waitFor(() => {
      const cards = Array.from(container.querySelectorAll('[data-testid="runtime-catalog-card"]'))
      expect(cards.length).toBe(3)
    })
    expect(container.querySelector('[data-testid="runtime-catalog-fallback"]')).toBeNull()
  })

  it('routing section shows resolved model routing controls and keeper assignments', async () => {
    stubRuntimeDefaults(
      makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [{ keeper: 'analyst', runtime_id: 'rt-b' }],
          librarian_runtime_id: 'rt-b',
          structured_judge_runtime_id: 'rt-c',
          cross_verifier_runtime_id: 'rt-a',
          media_failover: [],
        },
      }),
    )
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="runtime-routing-summary"]')?.textContent).toContain('Librarian')
      expect(container.querySelector('[data-testid="runtime-media-failover-reality"]')?.textContent)
        .toContain('수동 reroute')
      expect(container.querySelector('[data-testid="runtime-media-failover-reality"]')?.textContent)
        .toContain('provider 실패 자동 전환이 아니라')
      expect((container.querySelector('[data-testid="runtime-routing-structured-judge"]') as HTMLSelectElement | null)?.value)
        .toBe('rt-c')
      expect(container.querySelector('[data-testid="runtime-routing-cross-verifier"]')).not.toBeNull()
      expect(container.querySelector('[data-testid="runtime-media-failover-editor"]')).not.toBeNull()
      const assignments = Array.from(
        container.querySelectorAll('[data-testid="routing-assignment"]'),
      ).map(n => n.textContent)
      expect(assignments).toEqual(['rt-b'])
    })
  })

  it('patches scalar model routing lanes from settings and refreshes the projection', async () => {
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeDefaults
      .mockResolvedValueOnce(makeRuntimeDefaults())
      .mockResolvedValueOnce(makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [{ keeper: 'analyst', runtime_id: 'rt-b' }],
          librarian_runtime_id: 'rt-b',
          structured_judge_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: [],
        },
      }))
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)
    await waitFor(() => {
      const select = container.querySelector('[data-testid="runtime-routing-librarian"]') as HTMLSelectElement | null
      expect(select).not.toBeNull()
      expect(select?.disabled).toBe(false)
      expect(select?.options.length).toBeGreaterThan(1)
    })

    const librarian = container.querySelector('[data-testid="runtime-routing-librarian"]') as HTMLSelectElement
    await fireEvent.input(librarian, { target: { value: 'rt-b' } })

    await waitFor(() => {
      expect(apiMock.patchRuntimeRouting).toHaveBeenCalledWith('librarian', 'rt-b')
      expect(runtimeRefreshMock.refreshRuntimeConfigConsumers).toHaveBeenCalledTimes(1)
      expect((container.querySelector('[data-testid="runtime-routing-librarian"]') as HTMLSelectElement).value)
        .toBe('rt-b')
    })
    expect(container.querySelector('[data-testid="runtime-routing-message"]')?.textContent).toContain('저장됨')
  })

  it('routing section exposes a required default lane without an empty option and patches it', async () => {
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeDefaults.mockResolvedValue(makeRuntimeDefaults())
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)
    await waitFor(() => {
      const select = container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement | null
      expect(select).not.toBeNull()
      expect(select?.disabled).toBe(false)
    })

    const select = container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement
    const optionValues = Array.from(select.options).map(o => o.value)
    expect(optionValues).not.toContain('')

    await fireEvent.input(select, { target: { value: 'rt-b' } })
    await waitFor(() => {
      expect(apiMock.patchRuntimeRouting).toHaveBeenCalledWith('default', 'rt-b')
    })
  })

  it('runtime section default runtime is a writable selector that patches the default lane', async () => {
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeDefaults.mockResolvedValue(makeRuntimeDefaults())
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement)
    await waitFor(() => {
      const select = container.querySelector('[data-testid="runtime-default-runtime"]') as HTMLSelectElement | null
      expect(select?.tagName).toBe('SELECT')
      expect(select?.value).toBe('rt-a')
    })

    const select = container.querySelector('[data-testid="runtime-default-runtime"]') as HTMLSelectElement
    await fireEvent.input(select, { target: { value: 'rt-b' } })
    await waitFor(() => {
      expect(apiMock.patchRuntimeRouting).toHaveBeenCalledWith('default', 'rt-b')
    })
  })

  it('groups settings navigation by the keeper-v2 partial IA while keeping live-backed sections', () => {
    render(html`<${SettingsSurface} />`, container)

    const groups = Array.from(container.querySelectorAll('.set-nav-group'))
    const labels = groups.map(g => g.textContent ?? '')
    expect(labels.some(t => t.includes('Keeper 운영'))).toBe(true)
    expect(labels.some(t => t.includes('연결 · 통합'))).toBe(true)
    // 디자인이 nav에서 뺀 live-backed 섹션은 유지한다.
    expect(container.querySelector('[data-testid="settings-nav-mcp"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-display"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-routing"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-nav-repositories"]')).not.toBeNull()
  })

  it('patches ordered media failover from settings', async () => {
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeDefaults
      .mockResolvedValueOnce(makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [{ keeper: 'analyst', runtime_id: 'rt-b' }],
          librarian_runtime_id: null,
          structured_judge_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: ['rt-b'],
        },
      }))
      .mockResolvedValueOnce(makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [{ keeper: 'analyst', runtime_id: 'rt-b' }],
          librarian_runtime_id: null,
          structured_judge_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: ['rt-b', 'rt-c'],
        },
      }))
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)
    await waitFor(() => {
      const select = container.querySelector('[data-testid="runtime-media-failover-add"]') as HTMLSelectElement | null
      expect(select).not.toBeNull()
      expect(select?.disabled).toBe(false)
      expect(select?.options.length).toBeGreaterThan(1)
    })

    const add = container.querySelector('[data-testid="runtime-media-failover-add"]') as HTMLSelectElement
    await fireEvent.input(add, { target: { value: 'rt-c' } })

    await waitFor(() => {
      expect(apiMock.patchRuntimeMediaFailover).toHaveBeenCalledWith(['rt-b', 'rt-c'])
      expect(container.querySelector('[data-testid="runtime-media-failover-editor"]')?.textContent)
        .toContain('rt-c')
    })
  })

  it('routing section reports no assignments without fabricating rows', async () => {
    stubRuntimeDefaults(
      makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [],
          librarian_runtime_id: null,
          structured_judge_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: [],
        },
      }),
    )
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="routing-assignments-empty"]')).not.toBeNull()
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
    // 7 ring entries mapped to rows: tool(category/details or /masc_/)=4,
    // success(ok)=4, failure(fail)=2.
    apiMock.fetchLogs.mockResolvedValue({
      total: 7,
      entries: [
        makeLogEntry({
          seq: 7,
          level: 'INFO',
          message: 'shell exec completed',
          category: 'tool',
          details: { tool_name: 'shell.exec' },
        }),
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
    await waitFor(() => expect(allRows().length).toBe(7))

    const toolFilter = container.querySelector('[data-filter="tool"]') as HTMLButtonElement
    await fireEvent.click(toolFilter)
    expect(allRows().length).toBe(4)
    expect(container.textContent).toContain('shell exec completed')

    const successFilter = container.querySelector('[data-filter="success"]') as HTMLButtonElement
    await fireEvent.click(successFilter)
    expect(allRows().length).toBe(4)

    const failureFilter = container.querySelector('[data-filter="failure"]') as HTMLButtonElement
    await fireEvent.click(failureFilter)
    expect(allRows().length).toBe(2)

    const allFilter = container.querySelector('[data-filter="all"]') as HTMLButtonElement
    await fireEvent.click(allFilter)
    expect(allRows().length).toBe(7)
  })

  it('renders the live fusion settings writer from runtime.toml without an env gate', async () => {
    apiMock.fetchRuntimeTomlConfig.mockResolvedValueOnce({
      ok: true,
      path: MOCK_RUNTIME_PATH,
      file_name: 'runtime.toml',
      source_text: '[fusion]\nenabled = true\ndefault_preset = "trio"\nmax_concurrent_panels = 2\n\n[fusion.presets.trio]\nmin_answered = 2\n',
      reloaded: false,
    })
    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-fusion"]') as HTMLElement)

    await waitFor(() => expect(container.querySelector('[data-testid="fusion-settings-editor"]')).not.toBeNull())
    expect(apiMock.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    expect(container.querySelector('[data-testid="settings-section-state"]')?.textContent).toContain('runtime.toml live-backed')
    expect(container.querySelector('[data-testid="fusion-readonly-no-writer"]')).toBeNull()
    expect(container.querySelector('.set-card-b')?.getAttribute('data-preview-locked')).toBe('false')
    expect(container.querySelectorAll('.set-fus-lane').length).toBe(0)
    expect(container.textContent).not.toContain('per_hour_budget')
    expect(container.textContent).not.toContain('ollama_cloud.ollama-cloud-devstral-2-123b')
  })

  it('opens the live runtime.toml editor from runtime management', async () => {
    const runtimeConfig = {
      ok: true,
      path: MOCK_RUNTIME_PATH,
      file_name: 'runtime.toml',
      source_text: '[runtime]\ndefault = "runpod_mtp.qwen"\n',
      reloaded: false,
    }
    apiMock.fetchRuntimeTomlConfig.mockResolvedValueOnce(runtimeConfig)

    render(html`<${SettingsSurface} />`, container)

    await fireEvent.click(container.querySelector('[data-testid="settings-nav-runtimes"]') as HTMLElement)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="settings-section-title"]')?.textContent).toBe('런타임 관리')
      expect(container.querySelector('[data-testid="runtime-toml-editor"]')).not.toBeNull()
      expect(container.querySelector('.rt-overlay')).toBeNull()
      expect(container.textContent).toContain(MOCK_RUNTIME_PATH)
    })

    expect(apiMock.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })
})

describe('SettingsSurface shell route', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMock.fetchDashboardConfig.mockReset()
    apiMock.fetchLogs.mockReset()
    apiMock.fetchDashboardTools.mockReset()
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeProviders.mockReset()
    stubEmptyApi()
    dashboardLoading.value = false
    connected.value = true
    namespaceTruthInitializing.value = false
    document.title = 'MASC Dashboard'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
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
    expect(row).toEqual(['16:24:51', 'error', 'drifter', 'masc_trace_window 실패', 'fail', true])
  })

  it('logEntryToSysRow preserves structured tool classification for filters', () => {
    const row = logEntryToSysRow(
      makeLogEntry({
        category: 'tool',
        details: { tool_name: 'shell.exec' },
        message: 'shell exec completed',
      }),
    )
    expect(row[5]).toBe(true)
  })

  it('logEntryToSysRow falls back to module then (root) for identity', () => {
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: 'Server' }))[2]).toBe('Server')
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: '' }))[2]).toBe('(root)')
  })
})
