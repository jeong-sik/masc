import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// Writable route signal shared between mock and test helpers.
const routeSignal = signal<{ tab: string; params: Record<string, string>; postId: string | null }>({
  tab: 'monitoring',
  params: { section: 'fleet-health' },
  postId: null,
})

const fleetMock = vi.hoisted(() => {
  const sampleToolQuality = {
      generated_at: '2026-05-20T00:00:00Z',
      source: 'tool_call_io',
      health: 'ok',
      latest_age_s: 12,
      sampling_mode: 'window_hours',
      sample_limit: null,
      window_hours: 24,
      total: 30,
      success: 27,
      failure: 3,
      success_rate: 90,
      by_tool: [
        { name: 'masc_board_post', calls: 10, success_pct: 70, avg_ms: 120, output_truncated_count: 0, avg_output_chars: 1200 },
        { name: 'keeper_task_claim', calls: 20, success_pct: 100, avg_ms: 44, output_truncated_count: 1, avg_output_chars: 800 },
      ],
      by_keeper: [],
      failure_categories: [{ category: 'tool_error', count: 3 }],
      hourly_trend: [],
    }
  return {
    sampleToolQuality,
    sharedToolQuality: { value: sampleToolQuality as typeof sampleToolQuality | null },
    sharedToolQualityLoading: { value: false },
    sharedToolQualityError: { value: null as string | null },
    refreshSharedToolQuality: vi.fn(),
    cancelSharedToolQuality: vi.fn(),
  }
})

const storeMock = vi.hoisted(() => ({
  shellRuntimeResolution: { value: null as any },
  refreshShell: vi.fn(),
}))

function replaceRoute(tab: string, params?: Record<string, string>) {
  routeSignal.value = { tab, params: params ?? {}, postId: null }
  const query = new URLSearchParams(params ?? {}).toString()
  const hash = query ? `#${tab}?${query}` : `#${tab}`
  window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}${hash}`)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

function hashForRoute(tab: string, params?: Record<string, string>) {
  const query = new URLSearchParams(params ?? {}).toString()
  return query ? `#${tab}?${query}` : `#${tab}`
}

vi.mock('../router', () => ({
  get route() { return routeSignal },
  replaceRoute,
  hashForRoute,
  navigate: replaceRoute,
}))

vi.mock('./fleet-data-core', () => ({
  get sharedToolQuality() { return fleetMock.sharedToolQuality },
  get sharedToolQualityLoading() { return fleetMock.sharedToolQualityLoading },
  get sharedToolQualityError() { return fleetMock.sharedToolQualityError },
  refreshSharedToolQuality: fleetMock.refreshSharedToolQuality,
  cancelSharedToolQuality: fleetMock.cancelSharedToolQuality,
}))

vi.mock('../store', () => ({
  get shellRuntimeResolution() { return storeMock.shellRuntimeResolution },
  refreshShell: storeMock.refreshShell,
}))

// Mock child panels to avoid real fetch calls. Each renders a data-testid marker.
vi.mock('./telemetry-unified', () => ({
  TelemetryUnified: () => html`<div data-testid="telemetry-unified">TelemetryUnified</div>`,
}))
vi.mock('./fleet-telemetry-panel', () => ({
  FleetTelemetryPanel: () => html`<div data-testid="fleet-telemetry-panel">FleetTelemetryPanel</div>`,
}))
vi.mock('./tool-quality-panel', () => ({
  ToolQualityPanel: () => html`<div data-testid="tool-quality-panel">ToolQualityPanel</div>`,
}))
vi.mock('./gate-monitor', () => ({
  GateMonitor: () => html`<div data-testid="gate-monitor">GateMonitor</div>`,
}))
vi.mock('./keeper-reactivity-monitor', () => ({
  KeeperReactivityMonitor: () => html`<div data-testid="keeper-reactivity-monitor">KeeperReactivityMonitor</div>`,
}))

// Import after mocks are in place.
import { FleetHealthPanel, summarizeToolMonitorQuality } from './fleet-health-panel'

function setRoute(view?: string) {
  const params: Record<string, string> = { section: 'fleet-health' }
  if (view) params.view = view
  routeSignal.value = { tab: 'monitoring', params, postId: null }
}

describe('FleetHealthPanel', () => {
  beforeEach(() => {
    setRoute()
    fleetMock.sharedToolQuality.value = fleetMock.sampleToolQuality
    fleetMock.sharedToolQualityLoading.value = false
    fleetMock.sharedToolQualityError.value = null
    storeMock.shellRuntimeResolution.value = null
    storeMock.refreshShell.mockClear()
    fleetMock.refreshSharedToolQuality.mockClear()
    fleetMock.cancelSharedToolQuality.mockClear()
  })

  afterEach(() => {
    cleanup()
  })

  it('renders the compact Tool Monitor operations board when no view param', () => {
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('fleet-command-strip')).toBeTruthy()
    expect(screen.getByText('Keeper Fleet')).toBeTruthy()
    expect(screen.getByText('런타임 unknown')).toBeTruthy()
    expect(screen.getByTestId('tool-monitor-default')).toBeTruthy()
    expect(screen.getByText('Keeper tool readiness')).toBeTruthy()
    expect(screen.getAllByText('m:board_post').length).toBeGreaterThan(0)
    expect(screen.getByText('Full quality table')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
    expect(screen.queryByTestId('tool-quality-panel')).toBeNull()
    expect(screen.queryByTestId('fleet-telemetry-panel')).toBeNull()
    expect(screen.queryByTestId('gate-monitor')).toBeNull()
  })

  it('renders runtime fleet and contract blocker drilldown on the operations board', () => {
    storeMock.shellRuntimeResolution.value = {
      status: 'ready',
      warnings: [],
      fleet_safety: {
        keeper_fibers: 8,
        paused_keepers: 3,
        keeper_fleet_no_fibers: false,
        keeper_reaction_ledger: null,
        paused_keepers_health: {
          count: 3,
          names: ['analyst', 'base', 'sangsu'],
          running_count: 0,
          running_names: [],
          durable_count: 3,
          durable_names: ['analyst', 'base', 'sangsu'],
          autoboot_enabled_count: 3,
          autoboot_enabled_names: ['analyst', 'base', 'sangsu'],
          read_error_count: 0,
          read_errors: [],
          details: [{
            name: 'analyst',
            autoboot_enabled: true,
            pause_kind: 'operator_paused',
            paused_elapsed_sec: 12,
            last_blocker: null,
            missing_pause_root_cause: false,
          }],
        },
        keeper_fleet_safety: {
          status: 'degraded',
          reason: null,
          blocker: 'reaction_capacity_below_target',
          blocked_keepers: null,
          blocked_count: null,
          running_keeper_fiber_count: 8,
          executable_keeper_fiber_count: 13,
          effective_reaction_capacity_count: 8,
          executable_reaction_capacity_count: 13,
          target_reaction_capacity_count: 17,
          reaction_capacity_shortfall_count: 9,
          operator_action_required: true,
          reaction_capacity_below_target: true,
        },
      },
    }

    render(html`<${FleetHealthPanel} />`)

    expect(storeMock.refreshShell).toHaveBeenCalledWith({ force: true })
    expect(screen.getByTestId('fleet-command-strip')).toBeTruthy()
    expect(screen.getByText('런타임 가동')).toBeTruthy()
    expect(screen.getByText('capacity 8/17')).toBeTruthy()
    expect(screen.getByText('exec 13')).toBeTruthy()
    expect(screen.getByText('일시정지 3')).toBeTruthy()
    expect(screen.getByTestId('runtime-blocker-board')).toBeTruthy()
    expect(screen.getByText('8/17')).toBeTruthy()
    expect(screen.getByText('analyst')).toBeTruthy()
    expect(screen.getByText('operator_paused')).toBeTruthy()
    expect(screen.queryByText(/blocker=/)).toBeNull()
    expect(screen.queryByText(/manual pause applied/)).toBeNull()
  })

  it('marks the runtime health pill as warn when runtime.status is not ready', () => {
    storeMock.shellRuntimeResolution.value = {
      status: 'booting',
      warnings: [],
      fleet_safety: {
        keeper_fibers: 8,
        paused_keepers: 0,
        keeper_fleet_no_fibers: false,
        keeper_reaction_ledger: null,
        paused_keepers_health: { count: 0, names: [], running_count: 0, running_names: [], durable_count: 0, durable_names: [], autoboot_enabled_count: 0, autoboot_enabled_names: [], read_error_count: 0, read_errors: [], details: [] },
        keeper_fleet_safety: {
          status: 'ok',
          reason: null,
          blocker: null,
          blocked_keepers: null,
          blocked_count: null,
          running_keeper_fiber_count: 8,
          executable_keeper_fiber_count: 8,
          effective_reaction_capacity_count: 8,
          executable_reaction_capacity_count: 8,
          target_reaction_capacity_count: 8,
          reaction_capacity_shortfall_count: 0,
          operator_action_required: false,
          reaction_capacity_below_target: false,
        },
      },
    }

    render(html`<${FleetHealthPanel} />`)

    const runtimePill = screen.getByText('런타임 booting').closest('span')
    expect(runtimePill?.classList.contains('warn')).toBe(true)
    expect(runtimePill?.classList.contains('ok')).toBe(false)
  })

  it('renders TelemetryUnified alone for view=event-log', () => {
    setRoute('event-log')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('telemetry-unified')).toBeTruthy()
    expect(screen.queryByTestId('tool-quality-panel')).toBeNull()
  })

  it('renders FleetTelemetryPanel for view=comparison', () => {
    setRoute('comparison')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('fleet-telemetry-panel')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders ToolQualityPanel alone for view=tool-quality', () => {
    setRoute('tool-quality')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('tool-quality-panel')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders GateMonitor for view=gate', () => {
    setRoute('gate')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('gate-monitor')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders FilterChips with all 7 view options', () => {
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByText('Operations')).toBeTruthy()
    expect(screen.getByText('Evidence Log')).toBeTruthy()
    expect(screen.getByText('Keeper 비교')).toBeTruthy()
    expect(screen.getAllByText('Tool Quality').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Gate').length).toBeGreaterThan(0)
    expect(screen.getByText('Attribution')).toBeTruthy()
    expect(screen.getByText('반응성 모니터')).toBeTruthy()
  })

  it('marks the default chip as active (aria-selected)', () => {
    render(html`<${FleetHealthPanel} />`)

    const defaultChip = screen.getByText('Operations').closest('button')
    expect(defaultChip?.getAttribute('aria-selected')).toBe('true')
  })

  it('clicking a chip dispatches hashchange to switch view', () => {
    const hashChangeSpy = vi.fn()
    window.addEventListener('hashchange', hashChangeSpy)

    render(html`<${FleetHealthPanel} />`)

    const toolQualityChip = screen.getAllByText('Tool Quality')[0]
    expect(toolQualityChip).toBeTruthy()
    fireEvent.click(toolQualityChip!)

    expect(hashChangeSpy).toHaveBeenCalledTimes(1)
    expect(location.hash).toContain('view=tool-quality')

    window.removeEventListener('hashchange', hashChangeSpy)
  })

  it('clicking Operations chip removes view param from hash', () => {
    setRoute('tool-quality')
    render(html`<${FleetHealthPanel} />`)

    const defaultChip = screen.getByText('Operations')
    fireEvent.click(defaultChip)

    expect(location.hash).not.toContain('view=')
  })

  it('renders KeeperReactivityMonitor for view=keeper-health', () => {
    setRoute('keeper-health')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('keeper-reactivity-monitor')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
    expect(screen.queryByTestId('tool-quality-panel')).toBeNull()
  })

  it('falls back to default view for unknown view param', () => {
    setRoute('nonexistent')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('tool-monitor-default')).toBeTruthy()
  })

  it('keeps the default operations board visible when tool quality fetch fails', () => {
    fleetMock.sharedToolQuality.value = null
    fleetMock.sharedToolQualityError.value = '500 Internal Server Error'

    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('tool-monitor-default')).toBeTruthy()
    expect(screen.getByText('500 Internal Server Error')).toBeTruthy()
    expect(screen.getAllByText('Tool Quality').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Gate').length).toBeGreaterThan(0)
  })

  it('keeps lane links visible while the first tool quality fetch is pending', () => {
    fleetMock.sharedToolQuality.value = null
    fleetMock.sharedToolQualityLoading.value = true

    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('tool-monitor-default')).toBeTruthy()
    expect(screen.getByText('refreshing')).toBeTruthy()
    expect(screen.getByText('No tool observations.')).toBeTruthy()
    expect(screen.getAllByText('Tool Quality').length).toBeGreaterThan(0)
  })
})

describe('summarizeToolMonitorQuality', () => {
  it('preserves backend tool observations without local ranking', () => {
    const summary = summarizeToolMonitorQuality(fleetMock.sampleToolQuality)

    expect(summary.total).toBe(30)
    expect(summary.failure).toBe(3)
    expect(summary.rows.map(row => row.name)).toEqual([
      'masc_board_post',
      'keeper_task_claim',
    ])
  })
})
