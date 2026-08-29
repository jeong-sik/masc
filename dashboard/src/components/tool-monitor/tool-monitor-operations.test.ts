// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const navigateMock = vi.hoisted(() => vi.fn())

const fleetMock = vi.hoisted(() => {
  const sampleToolQuality = {
    generated_at: '2026-08-23T00:00:00Z',
    source: 'tool_call_io',
    health: 'ok',
    latest_age_s: 42,
    entry_count: 128410,
    sampling_mode: 'window_hours',
    sample_limit: null,
    window_hours: 24,
    total: 100,
    success: 96,
    failure: 4,
    deferred: 0,
    success_rate: 96,
    by_tool: [
      { name: 'keeper_board_list', calls: 60, success_pct: 99.5, avg_ms: 120, avg_output_chars: 2400 },
      { name: 'tool_execute', calls: 40, success_pct: 88.0, avg_ms: 18420, output_truncated_count: 2 },
    ],
    by_keeper: [],
    failure_categories: [{ category: 'exec_nonzero_exit', count: 7 }],
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
  refreshShell: vi.fn(() => Promise.resolve()),
}))

vi.mock('../../router', () => ({
  navigate: navigateMock,
}))

vi.mock('../fleet-data-core', () => ({
  get sharedToolQuality() { return fleetMock.sharedToolQuality },
  get sharedToolQualityLoading() { return fleetMock.sharedToolQualityLoading },
  get sharedToolQualityError() { return fleetMock.sharedToolQualityError },
  refreshSharedToolQuality: fleetMock.refreshSharedToolQuality,
  cancelSharedToolQuality: fleetMock.cancelSharedToolQuality,
}))

vi.mock('../../store', () => ({
  get shellRuntimeResolution() { return storeMock.shellRuntimeResolution },
  refreshShell: storeMock.refreshShell,
}))

vi.mock('../../lib/auto-refresh', () => ({
  formatAutoRefreshLabel: () => '자동 갱신 30s',
  setupVisibleAutoRefresh: () => () => {},
}))

// Avoid pulling the whole fleet-health panel tree; mirror the real summary
// projection and the local not-running subtraction
// (src/components/fleet-health-panel.ts).
vi.mock('../fleet-health-panel', () => ({
  summarizeToolMonitorQuality: (quality: any) => ({
    total: quality?.total ?? 0,
    successRate: quality?.success_rate ?? 0,
    failure: quality?.failure ?? 0,
    deferred: quality?.deferred ?? 0,
    rows: quality?.by_tool ?? [],
  }),
  keepersNotRunning: (fleet: any) => {
    const executable = new Set(fleet?.executable_keeper_names ?? [])
    return (fleet?.autoboot_enabled_keeper_names ?? [])
      .filter((name: string) => !executable.has(name))
      .sort()
  },
}))

import { ToolMonitorOperationsBoard } from './tool-monitor-operations'

function runtimeSample() {
  return {
    status: 'ready',
    warnings: [],
    fleet_safety: {
      keeper_fibers: 8,
      paused_keepers: 1,
      keeper_reaction_ledger: null,
      keeper_fleet_safety: {
        status: 'degraded',
        executable_keeper_fiber_count: 5,
        target_reaction_capacity_count: 7,
        reaction_capacity_shortfall_count: 2,
        paused_keeper_count: 1,
        // The server reports both lists; not-running is the local subtraction.
        autoboot_enabled_keeper_names: ['nick0cave', 'masc-improver', 'drifter', 'librarian', 'retro-01', 'sangsu'],
        executable_keeper_names: ['nick0cave', 'masc-improver', 'drifter', 'librarian', 'retro-01'],
      },
      paused_keepers_health: {
        count: 1,
        names: ['nick0cave'],
        durable_count: 1,
        durable_names: ['nick0cave'],
        autoboot_enabled_count: 1,
        autoboot_enabled_names: ['nick0cave'],
        read_error_count: 1,
        read_errors: [{ keeper: 'ghost-04', error: 'paused-state read 실패' }],
        details: [{
          name: 'nick0cave',
          autoboot_enabled: true,
          pause_kind: 'operator',
          paused_elapsed_sec: 1840,
          missing_pause_root_cause: false,
        }],
      },
    },
  }
}

describe('ToolMonitorOperationsBoard', () => {
  beforeEach(() => {
    fleetMock.sharedToolQuality.value = fleetMock.sampleToolQuality
    fleetMock.sharedToolQualityLoading.value = false
    fleetMock.sharedToolQualityError.value = null
    storeMock.shellRuntimeResolution.value = null
    navigateMock.mockClear()
  })

  afterEach(() => {
    cleanup()
  })

  it('renders the design board vocabulary with live source strip and tiles', () => {
    const { container } = render(html`<${ToolMonitorOperationsBoard} />`)

    expect(container.querySelector('.tm-board')).toBeTruthy()
    expect(container.querySelector('.tm-src')?.textContent).toContain('tool_call_io')
    expect(container.querySelector('.tm-src .ok')?.textContent).toBe('ok')
    expect(container.querySelector('.tm-src')?.textContent).toContain('128,410 durable rows')
    expect(container.querySelector('.tm-src')?.textContent).toContain('최근 24h')

    const tiles = container.querySelectorAll('.tm-tile')
    expect(tiles.length).toBe(5)
    expect(screen.getByText('Success')).toBeTruthy()
    expect(screen.getByText('96.0%')).toBeTruthy()
    expect(screen.getByText('Reaction capacity')).toBeTruthy()
  })

  it('renders not-running keepers and paused diagnostics from the runtime sample', () => {
    storeMock.shellRuntimeResolution.value = runtimeSample()
    const { container } = render(html`<${ToolMonitorOperationsBoard} />`)

    expect(screen.getByText('기동하지 않는 Keeper')).toBeTruthy()
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('기동하지 않음')

    expect(screen.getByText('Paused keeper diagnostics')).toBeTruthy()
    expect(screen.getAllByText('nick0cave').length).toBeGreaterThan(0)
    expect(container.textContent).toContain('operator')
    expect(container.textContent).toContain('31m')
    const failRow = container.querySelector('tr.fail')
    expect(failRow?.textContent).toContain('ghost-04')

    // capacity tile: 5/7 with shortfall sub, paused tile: 1 with names
    expect(screen.getByText('5/7')).toBeTruthy()
    expect(screen.getByText('shortfall 2')).toBeTruthy()
  })

  it('renders tool observations table and failure categories from tool-quality', () => {
    const { container } = render(html`<${ToolMonitorOperationsBoard} />`)

    expect(screen.getByText('Tool observations')).toBeTruthy()
    expect(container.textContent).toContain('board_list')
    expect(container.textContent).toContain('execute')
    expect(container.textContent).toContain('88.0%')
    expect(container.textContent).toContain('2 clipped')

    expect(screen.getByText('Failure categories')).toBeTruthy()
    const cat = container.querySelector('.tm-cat')
    expect(cat?.textContent).toContain('exec_nonzero_exit')
    expect(cat?.textContent).toContain('7x')
  })

  it('lanes and full-table link navigate to fleet-health sub-views', () => {
    const { container } = render(html`<${ToolMonitorOperationsBoard} />`)

    const lanes = container.querySelectorAll('.tm-lane')
    expect(lanes.length).toBe(4)
    fireEvent.click(lanes[1]!)
    expect(navigateMock).toHaveBeenCalledWith('monitoring', { section: 'fleet-health', view: 'gate' })

    fireEvent.click(screen.getByText('전체 품질 표 →'))
    expect(navigateMock).toHaveBeenCalledWith('monitoring', { section: 'fleet-health', view: 'tool-quality' })
  })

  it('renders dim empty treatments when there is no live signal', () => {
    fleetMock.sharedToolQuality.value = null
    const { container } = render(html`<${ToolMonitorOperationsBoard} />`)

    expect(container.textContent).toContain('no sample')
    expect(container.textContent).toContain('관측된 도구 호출 없음')
    // With no runtime sample the subtraction has no operands, so the
    // not-running section reports the all-running empty state.
    expect(container.textContent).toContain('모든 Keeper 가 돌고 있습니다')
    expect(container.textContent).toContain('일시정지된 키퍼 없음')
    expect(container.textContent).toContain('실패 카테고리 없음')
  })
})
