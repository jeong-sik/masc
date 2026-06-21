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
} from './settings-surface'
import type { DashboardToolInventoryItem } from '../api/dashboard'
import type { LogEntry } from '../api/schemas/logs'
import type { RuntimeDefaultsResponse } from '../api/schemas/runtime-defaults'
import { DashboardMain } from './dashboard-shell'
import { route } from '../router'
import { connected } from '../sse'
import { dashboardLoading } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'

const apiMock = vi.hoisted(() => ({
  fetchLogs: vi.fn(),
  fetchDashboardTools: vi.fn(),
  fetchRuntimeDefaults: vi.fn(),
}))

vi.mock('../api/dashboard.js', async () => {
  const actual = await vi.importActual<typeof import('../api/dashboard')>('../api/dashboard')
  return {
    ...actual,
    fetchLogs: apiMock.fetchLogs,
    fetchDashboardTools: apiMock.fetchDashboardTools,
    fetchRuntimeDefaults: apiMock.fetchRuntimeDefaults,
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

function stubRuntimeDefaults(value: RuntimeDefaultsResponse = makeRuntimeDefaults()) {
  apiMock.fetchRuntimeDefaults.mockResolvedValue(value)
}

function stubEmptyApi() {
  apiMock.fetchLogs.mockResolvedValue({ total: 0, entries: [] })
  apiMock.fetchDashboardTools.mockResolvedValue({ tool_inventory: { count: 0, tools: [] } })
  stubRuntimeDefaults()
}

const navigate = vi.fn()
vi.mock('../router', async () => {
  const actual = await vi.importActual<typeof import('../router')>('../router')
  return {
    ...actual,
    navigate: (...args: Parameters<typeof navigate>) => navigate(...args),
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
    stubEmptyApi()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    navigate.mockClear()
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
  })

  it('toggle control changes state', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    const toggle = () => container.querySelector('[data-testid="set-toggle"]') as HTMLButtonElement
    expect(toggle().getAttribute('aria-checked')).toBe('true')

    await fireEvent.click(toggle())
    expect(toggle().getAttribute('aria-checked')).toBe('false')

    await fireEvent.click(toggle())
    expect(toggle().getAttribute('aria-checked')).toBe('true')
  })

  it('segmented control changes state', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    const seg = () => container.querySelector('[data-testid="set-seg"]') as HTMLElement
    // The Default runtime segmented control renders from resolved runtime config.
    await waitFor(() => expect(seg()).not.toBeNull())
    const buttons = () => Array.from(seg().querySelectorAll('button'))
    expect(buttons().length).toBeGreaterThanOrEqual(3)
    expect(buttons()[0]!.getAttribute('data-active')).toBe('true')

    await fireEvent.click(buttons()[2]!)
    expect(buttons()[0]!.getAttribute('data-active')).toBe('false')
    expect(buttons()[2]!.getAttribute('data-active')).toBe('true')
  })

  it('Default runtime/model options come from the resolved runtime config', async () => {
    render(html`<${SettingsSurface} />`, container)

    const runtimeNav = container.querySelector('[data-testid="settings-nav-runtime"]') as HTMLElement
    await fireEvent.click(runtimeNav)

    await waitFor(() => {
      const segLabels = Array.from(
        container.querySelectorAll('[data-testid="set-seg"] button'),
      ).map(b => b.textContent?.trim())
      // runtime ids from the mocked registry, not the old hardcoded oas-* strings
      expect(segLabels).toContain('rt-a')
      expect(segLabels).toContain('rt-b')
      expect(segLabels).toContain('rt-c')
      expect(segLabels).not.toContain('oas·seoul-1')
    })
  })

  it('routing section shows resolved keeper assignments read-only', async () => {
    render(html`<${SettingsSurface} />`, container)

    const routingNav = container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement
    await fireEvent.click(routingNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="routing-default-model"]')?.textContent).toBe('m1')
      const assignments = Array.from(
        container.querySelectorAll('[data-testid="routing-assignment"]'),
      ).map(n => n.textContent)
      expect(assignments).toEqual(['rt-b'])
    })
  })

  it('routing section reports no assignments without fabricating rows', async () => {
    stubRuntimeDefaults(
      makeRuntimeDefaults({
        model_routing: {
          keeper_assignments: [],
          librarian_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: [],
        },
      }),
    )
    render(html`<${SettingsSurface} />`, container)

    const routingNav = container.querySelector('[data-testid="settings-nav-routing"]') as HTMLElement
    await fireEvent.click(routingNav)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="routing-assignments-empty"]')).not.toBeNull()
    })
    expect(container.querySelectorAll('[data-testid="routing-assignment"]').length).toBe(0)
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
    expect(row).toEqual(['16:24:51', 'error', 'drifter', 'masc_trace_window 실패', 'fail'])
  })

  it('logEntryToSysRow falls back to module then (root) for identity', () => {
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: 'Server' }))[2]).toBe('Server')
    expect(logEntryToSysRow(makeLogEntry({ keeper_name: null, module: '' }))[2]).toBe('(root)')
  })
})
