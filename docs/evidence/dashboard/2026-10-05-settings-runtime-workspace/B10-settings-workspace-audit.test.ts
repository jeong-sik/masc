// Audit-only reproduction: assertions below describe the defect, not desired behavior.
// Original component test fixture setup is reused verbatim below. Production source is unchanged.
import { executionWorkspaceAuthority } from '../store'
import { patchRuntimeRouting as actualPatchRuntimeRouting } from '../api/dashboard-runtime'
const tokenGate = vi.hoisted(() => ({ ensure: vi.fn(async () => undefined) }))
vi.mock('../api/dev-token', async () => ({
  ...await vi.importActual<typeof import('../api/dev-token')>('../api/dev-token'),
  ensureDevToken: tokenGate.ensure,
}))
import * as coreApi from '../api/core'
import * as dashboardApi from '../api/dashboard'
import { modelSetupResumeState } from '../lib/model-setup-resume'
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { Effect } from 'effect'
import {
  SettingsSurface,
  mcpExposedToolNames,
  mcpExposedToolGroups,
  logEntryToSysRow,
  logRowStatus,
  normalizeSettingsSection,
  settingsControlInventory,
} from './settings-surface'
import type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  FusionConfigSnapshot,
  RuntimeDefaultsResponse,
  RuntimeResolvedResponse,
} from '../api/dashboard'
import type { ConfigEntry, DashboardConfig } from '../api/dashboard-config'
import type { LogEntry, LogsData } from '../api/dashboard-logs'
import { DashboardMain } from './dashboard-shell'
import { SETTINGS_ROUTE_SECTION_IDS } from '../config/navigation'
import { route } from '../router'
import { dashboardWsConnected } from '../dashboard-ws-state'
import { tweaksDensity } from './tweaks-panel'
import { notificationDeliveryError, notifyRules } from '../notifications'
import {
  committedRuntimeTomlConfigFixture,
  runtimeReservedProviderIdsFixture,
} from '../lib/runtime-config-receipt.test-fixture'

const MOCK_RUNTIME_PATH = 'fixture/config/runtime.toml'
const runtimeProviderProtocols = [
  {
    protocol: 'openai-compatible-http',
    transport: 'endpoint',
    semantics: 'http_provider',
    credential_policy: 'optional',
    requires_non_interactive: false,
    provider_fields: [],
    required_provider_fields: [],
  },
] as const
import { dashboardLoading, shellAuthSummary, shellConfigResolution, shellRuntimeResolution } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'
import { resetDevTokenBootstrap } from '../api/dev-token'
import { setStoredToken } from '../api/core'
import type { RuntimeLaneEdit } from '../api/dashboard'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { resetRuntimeTomlSessionsForTesting } from '../lib/runtime-toml-session'
import { runtimeTomlSourceGeneration } from '../lib/runtime-toml-source-generation'

const apiMock = vi.hoisted(() => ({
  fetchDashboardConfig: vi.fn(),
  fetchLogs: vi.fn(),
  fetchDashboardTools: vi.fn(),
  fetchRuntimeDefaults: vi.fn(),
  fetchRuntimeResolved: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
  fetchRuntimeTomlConfig: vi.fn(),
  fetchFusionConfig: vi.fn(),
  patchRuntimeMediaFailover: vi.fn(),
  patchRuntimeRouting: vi.fn(),
  patchRuntimeLane: vi.fn(),
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
        key: 'keeper',
        category: 'keeper',
        description: 'Shared world prompt',
        current: 'Hello {{keeper}} in {{namespace}}',
        default: 'Hello {{keeper}} in {{namespace}}',
        effective: 'Hello {{keeper}} in {{namespace}}',
        file_value: 'Hello {{keeper}} in {{namespace}}',
        override_value: null,
        file_path: 'fixture/config/prompts/keeper.md',
        source: 'file' as const,
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
    fetchDashboardTools: apiMock.fetchDashboardTools,
    fetchRuntimeDefaults: apiMock.fetchRuntimeDefaults,
    fetchRuntimeResolved: apiMock.fetchRuntimeResolved,
    fetchRuntimeProviders: apiMock.fetchRuntimeProviders,
    fetchRuntimeTomlConfig: apiMock.fetchRuntimeTomlConfig,
    fetchFusionConfig: apiMock.fetchFusionConfig,
    patchRuntimeMediaFailover: apiMock.patchRuntimeMediaFailover,
    patchRuntimeRouting: apiMock.patchRuntimeRouting,
    patchRuntimeLane: apiMock.patchRuntimeLane,
    saveRuntimeTomlConfig: apiMock.saveRuntimeTomlConfig,
  }
})

vi.mock('../api/onboarding', () => ({
  fetchSetupStatus: vi.fn(async () => ({ schema: 'masc.onboarding_status.v1', base_path: '/fixture', selected_model: null, selected_runtime: null, checks: [] })),
  fetchSetupInventory: vi.fn(async () => ({ source_revision: 'fixture-revision', runtimes: [] })),
  saveSetupCredential: vi.fn(),
}))

vi.mock('../api/dashboard-config', () => ({
  fetchDashboardConfig: apiMock.fetchDashboardConfig,
}))

vi.mock('../api/dashboard-logs', () => ({
  fetchLogs: apiMock.fetchLogs,
}))

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
    timestamp: '2026-06-21T16:24:51Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    message: 'booted',
    keeperName: 'system',
    hasTurn: false,
    category: null,
    details: {},
    ...overrides,
  }
}

function makeLogsData(entries: readonly LogEntry[]): LogsData {
  return {
    generatedAt: '2026-06-21T16:24:51Z',
    source: 'masc_log_ring',
    retention: {
      scope: 'dashboard_logs',
      durableStore: '/workspace/.masc/logs/system_log_2026-06-21.jsonl',
    },
    ring: { startSeq: 0, total: entries.length, droppedBefore: false },
    total: entries.length,
    entries,
  }
}

function makeToolItem(overrides: Partial<DashboardToolInventoryItem> = {}): DashboardToolInventoryItem {
  return {
    name: 'tool',
    description: '',
    category: 'uncategorized',
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

function makeModelRouting(
  overrides: {
    media_failover?: string[]
  } = {},
): RuntimeDefaultsResponse['model_routing'] {
  return {
    media_failover: [],
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
    model_routing: makeModelRouting(),
    ...overrides,
  }
}

function makeRuntimeResolved(
  overrides: Partial<RuntimeResolvedResponse> = {},
): RuntimeResolvedResponse {
  return {
    generated_at_iso: '2026-06-21T00:00:00Z',
    source: '/api/v1/runtime/resolved',
    config_path: '/cfg/runtime.toml',
    default_runtime: {
      id: 'rt-a', provider: 'P', model: 'm1',
      effective_max_context: 128000, max_context_source: 'override',
      max_output_tokens: null, is_local: false, is_default: true,
    },
    runtimes: [
      {
        id: 'rt-a', provider: 'P', model: 'm1',
        effective_max_context: 128000, max_context_source: 'override',
        max_output_tokens: null, is_local: false, is_default: true,
      },
      {
        id: 'rt-b', provider: 'P', model: 'm2',
        effective_max_context: 128000, max_context_source: 'override',
        max_output_tokens: null, is_local: false, is_default: false,
      },
      {
        id: 'rt-c', provider: 'P', model: 'm3',
        effective_max_context: 128000, max_context_source: 'override',
        max_output_tokens: null, is_local: false, is_default: false,
      },
    ],
    lanes: [],
    assignments: [
      { keeper: 'analyst', assignment_source: 'explicit', resolved: { kind: 'single_runtime', id: 'rt-b' } },
    ],
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
    assignment_status: null,
    config_path: '/cfg/runtime.toml',
    ...overrides,
  }
}

function makeConfigEntry(overrides: Partial<ConfigEntry> = {}): ConfigEntry {
  return {
    env: 'MASC_BASE_PATH',
    description: 'Base storage directory',
    displayValue: '(cwd)',
    defaultValue: '(cwd)',
    source: 'runtime',
    sourceDetail: 'resolved from runtime',
    sensitive: false,
    ...overrides,
  }
}

function makeDashboardConfig(overrides: Partial<DashboardConfig> = {}): DashboardConfig {
  return {
    server: {
      version: 'test',
      ocamlVersion: '5.4.0',
      uptimeSeconds: 12,
      pid: 123,
    },
    categories: {
      server: [
        makeConfigEntry({ env: 'MASC_URL', description: 'MCP URL', displayValue: 'http://127.0.0.1:8935/mcp', defaultValue: '(derived)', source: 'env', sourceDetail: 'environment variable MASC_URL' }),
        makeConfigEntry({ env: 'MASC_HTTP_BASE_URL', description: 'HTTP base URL', displayValue: 'http://127.0.0.1:8935', defaultValue: '(derived)', source: 'env', sourceDetail: 'environment variable MASC_HTTP_BASE_URL' }),
        makeConfigEntry({ env: 'MASC_BASE_PATH', description: 'Base storage directory', displayValue: '/workspace', defaultValue: '(cwd)', source: 'env', sourceDetail: 'environment variable MASC_BASE_PATH' }),
      ],
      path: [
        makeConfigEntry({ env: 'MASC_CONFIG_DIR', description: 'Config directory override', displayValue: '(none)', defaultValue: '(none)', source: 'default', sourceDetail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DATA_DIR', description: 'Data directory override', displayValue: '(none)', defaultValue: '(none)', source: 'default', sourceDetail: 'compiled default value' }),
      ],
      dashboard: [
        makeConfigEntry({ env: 'MASC_DASHBOARD_CTX_PREPARING', description: 'Context preparing', displayValue: '0.70', defaultValue: '0.70', source: 'default', sourceDetail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_CTX_HANDOFF_IMMINENT', description: 'Context imminent', displayValue: '0.85', defaultValue: '0.85', source: 'default', sourceDetail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO', description: 'Runtime warning', displayValue: '0.95', defaultValue: '0.95', source: 'default', sourceDetail: 'compiled default value' }),
        makeConfigEntry({ env: 'MASC_DASHBOARD_SIGNAL_STALE_SEC', description: 'Signal stale', displayValue: '1200.0', defaultValue: '1200.0', source: 'default', sourceDetail: 'compiled default value' }),
      ],
    },
    ...overrides,
  }
}

function stubRuntimeDefaults(value: RuntimeDefaultsResponse = makeRuntimeDefaults()) {
  apiMock.fetchRuntimeDefaults.mockResolvedValue(value)
}

function makeFusionConfig(): FusionConfigSnapshot {
  return {
    enabled: true,
    defaultPreset: 'trio',
    stagedJudgeGroupSize: 3,
    sourceRevision: 'fusion-revision',
    presets: [
      {
        name: 'trio',
        panels: [
          {
            models: ['rt-a', 'rt-b'],
            label: '',
            systemPrompt: 'panelist',
            webTools: false,
            maxOutputTokens: null,
            timeoutS: null,
          },
        ],
        judge: 'rt-c',
        judgeSystemPrompt: 'judge',
        judgeMaxOutputTokens: null,
        judgeTimeoutS: null,
        judges: [],
        minAnswered: 2,
      },
    ],
  }
}

const realConfirm = window.confirm

function setConfirm(value: ((message?: string) => boolean) | undefined): void {
  Object.defineProperty(window, 'confirm', { value, configurable: true, writable: true })
}

function stubRuntimeResolved(value: RuntimeResolvedResponse = makeRuntimeResolved()) {
  apiMock.fetchRuntimeResolved.mockResolvedValue(value)
}

function stubEmptyApi() {
  apiMock.fetchDashboardConfig.mockReturnValue(Effect.succeed(makeDashboardConfig()))
  apiMock.fetchLogs.mockReturnValue(Effect.succeed(makeLogsData([])))
  apiMock.fetchDashboardTools.mockResolvedValue({ tool_inventory: { count: 0, tools: [] } })
  stubRuntimeDefaults()
  stubRuntimeResolved()
  apiMock.fetchRuntimeProviders.mockResolvedValue(makeRuntimeProviders())
  apiMock.fetchRuntimeTomlConfig.mockResolvedValue({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    reloaded: false,
    provider_protocols: runtimeProviderProtocols,
  })
  apiMock.fetchFusionConfig.mockResolvedValue(makeFusionConfig())
  apiMock.patchRuntimeMediaFailover.mockImplementation(async () => committedRuntimeTomlConfigFixture({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    provider_protocols: runtimeProviderProtocols,
  }))
  apiMock.patchRuntimeRouting.mockImplementation(async () => committedRuntimeTomlConfigFixture({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    provider_protocols: runtimeProviderProtocols,
  }))
  apiMock.patchRuntimeLane.mockImplementation(async () => committedRuntimeTomlConfigFixture({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: '[runtime]\ndefault = "rt-a"\n',
    provider_protocols: runtimeProviderProtocols,
  }))
  apiMock.saveRuntimeTomlConfig.mockImplementation(async (sourceText: string) => committedRuntimeTomlConfigFixture({
    ok: true,
    path: MOCK_RUNTIME_PATH,
    file_name: 'runtime.toml',
    source_text: sourceText,
    provider_protocols: runtimeProviderProtocols,
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
    modelSetupResumeState.value = { kind: 'idle' }
    vi.spyOn(coreApi, 'post').mockResolvedValue({ runtime_ready: true,
      exact_output_authority_available: true, model_setup: { status: 'available' } })
    container = document.createElement('div')
    document.body.appendChild(container)
    apiMock.fetchDashboardConfig.mockReset()
    apiMock.fetchLogs.mockReset()
    apiMock.fetchDashboardTools.mockReset()
    apiMock.fetchRuntimeDefaults.mockReset()
    apiMock.fetchRuntimeResolved.mockReset()
    apiMock.fetchRuntimeProviders.mockReset()
    apiMock.fetchRuntimeTomlConfig.mockReset()
    apiMock.fetchFusionConfig.mockReset()
    apiMock.patchRuntimeMediaFailover.mockReset()
    apiMock.patchRuntimeRouting.mockReset()
    apiMock.patchRuntimeLane.mockReset()
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
      disk_observation: null,
    }
    shellConfigResolution.value = {
      status: 'ready',
      warnings: [],
      config_root: { path: '/workspace/.masc/config', exists: true, source: 'derived' },
      prompts: { path: '/workspace/.masc/config/prompts', exists: true, source: 'derived' },
      keepers: { path: '/workspace/.masc/keepers', exists: true, source: 'derived' },
    }
    shellAuthSummary.value = null
    localStorage.clear()
    tweaksDensity.value = 'spacious'
    notifyRules.value = {
      'approval:pending': true,
      'agent_core:agent_failed': true,
    }
    notificationDeliveryError.value = null
    window.location.hash = '#settings'
    route.value = { tab: 'settings', params: {}, postId: null }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    navigate.mockClear()
    shellConfigResolution.value = null
    shellRuntimeResolution.value = null
    shellAuthSummary.value = null
    resetDevTokenBootstrap()
    sessionStorage.clear()
    localStorage.clear()
    tweaksDensity.value = 'spacious'
    vi.unstubAllGlobals()
    vi.unstubAllEnvs()
  })


  let epochSequence = 0
  function workspace(name: string) {
    const epoch = `B10-${name}-${++epochSequence}`
    invalidateExecutionSnapshotGeneration(epoch, 0)
    hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: 1,
      status: { project: name, workspace_root: `/audit/${name}` },
    } as Parameters<typeof hydrateExecutionSnapshot>[0])
    expect(executionWorkspaceAuthority.peek()?.workspaceRoot).toBe(`/audit/${name}`)
  }
  function deferred<T>() {
    let resolve!: (value: T) => void
    const promise = new Promise<T>(yes => { resolve = yes })
    return { promise, resolve }
  }
  async function openRouting() {
    render(html`<${SettingsSurface} />`, container)
    await fireEvent.click(container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement)
    await waitFor(() => {
      const select = container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement
      expect(select).not.toBeNull()
      expect(select.disabled).toBe(false)
    })
    return container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement
  }
  beforeEach(() => {
    resetRuntimeTomlSessionsForTesting()
    tokenGate.ensure.mockReset().mockResolvedValue(undefined)
    workspace('A')
  })
  afterEach(() => {
    resetRuntimeTomlSessionsForTesting()
    vi.restoreAllMocks()
  })

  it('B10 loaded A routing remains visible and writable after authority becomes B', async () => {
    const select = await openRouting()
    const mountedSurface = container.querySelector('[data-testid="settings-surface"]')
    expect(select.value).toBe('rt-a')
    await waitFor(() => expect(apiMock.fetchRuntimeProviders).toHaveBeenCalledTimes(1))
    apiMock.fetchRuntimeDefaults.mockResolvedValue(makeRuntimeDefaults({ default_runtime_id: 'rt-c' }))
    apiMock.fetchRuntimeResolved.mockResolvedValue(makeRuntimeResolved({ default_runtime: {
      ...makeRuntimeResolved().default_runtime!, id: 'rt-c',
    } }))
    workspace('B')
    await waitFor(() => expect(executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/audit/B'))
    await new Promise(resolve => setTimeout(resolve, 40))
    expect(container.querySelector('[data-testid="settings-surface"]')).toBe(mountedSurface)
    expect((container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement).value).toBe('rt-a')
    expect((container.querySelector('[data-testid="runtime-routing-default"]') as HTMLSelectElement).disabled).toBe(false)
    expect(apiMock.fetchRuntimeDefaults).toHaveBeenCalledTimes(1)
    expect(apiMock.fetchRuntimeResolved).toHaveBeenCalledTimes(1)
    expect(apiMock.fetchRuntimeProviders).toHaveBeenCalledTimes(1)
    console.info('B10 loaded reading: authority=B, same mounted Settings, A default=rt-a still enabled; no B defaults/resolved/providers GET')
  })

  it('B10 late A resolved response is accepted after workspace B is current', async () => {
    const pending = deferred<RuntimeResolvedResponse>()
    apiMock.fetchRuntimeResolved.mockReturnValueOnce(pending.promise)
    render(html`<${SettingsSurface} />`, container)
    await fireEvent.click(container.querySelector('[data-testid="settings-nav-paths"]') as HTMLElement)
    await waitFor(() => expect(apiMock.fetchRuntimeResolved).toHaveBeenCalledTimes(1))
    workspace('B')
    pending.resolve(makeRuntimeResolved({ config_path: '/audit/A/runtime.toml' }))
    await waitFor(() => expect(container.textContent).toContain('/audit/A/runtime.toml'))
    expect(executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/audit/B')
    expect(apiMock.fetchRuntimeResolved).toHaveBeenCalledTimes(1)
    console.info('B10 late reading: A config_path accepted and rendered while actual execution authority is B')
  })

  it('B10 actual routing API dispatches A selection after token await resumes under B', async () => {
    const select = await openRouting()
    const token = deferred<void>()
    tokenGate.ensure.mockImplementationOnce(() => token.promise)
    apiMock.patchRuntimeRouting.mockImplementation(actualPatchRuntimeRouting)
    const dispatches: { path: string; body: unknown; workspace: string | null }[] = []
    vi.mocked(coreApi.post).mockImplementation(async (path, body) => {
      dispatches.push({ path, body, workspace: executionWorkspaceAuthority.peek()?.workspaceRoot ?? null })
      throw new Error('Audit transport ends here; no server write is performed')
    })
    await fireEvent.input(select, { target: { value: 'rt-b' } })
    await waitFor(() => expect(tokenGate.ensure).toHaveBeenCalledTimes(1))
    expect(dispatches).toEqual([])
    workspace('B')
    token.resolve(undefined)
    await waitFor(() => expect(dispatches).toHaveLength(1))
    expect(dispatches[0]).toEqual({ path: '/api/v1/runtime/config/routing',
      body: { lane: 'default', runtime_id: 'rt-b' }, workspace: '/audit/B' })
    console.info('B10 actual API dispatch: A selected rt-b; token suspended; authority changed to B; POST transport received default=rt-b under B. Mock rejects before any server effect.')
  })
})
