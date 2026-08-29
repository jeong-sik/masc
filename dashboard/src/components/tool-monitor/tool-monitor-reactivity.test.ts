// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../../types'

const storeMock = vi.hoisted(() => ({
  keepers: { value: [] as Keeper[] },
  shellRuntimeResolution: { value: null as any },
  refreshShell: vi.fn(() => Promise.resolve()),
}))

const keeperApiMock = vi.hoisted(() => ({
  fetchKeeperTransitions: vi.fn(),
  fetchKeeperLifecycle: vi.fn(),
}))

vi.mock('../../store', () => ({
  get keepers() { return storeMock.keepers },
  get shellRuntimeResolution() { return storeMock.shellRuntimeResolution },
  refreshShell: storeMock.refreshShell,
}))

vi.mock('../../api/keeper', () => ({
  fetchKeeperTransitions: keeperApiMock.fetchKeeperTransitions,
  fetchKeeperLifecycle: keeperApiMock.fetchKeeperLifecycle,
}))

import { ToolMonitorReactivityBoard } from './tool-monitor-reactivity'

function keeper(overrides: Partial<Keeper>): Keeper {
  return { name: 'k', status: 'active', ...overrides } satisfies Keeper
}

describe('ToolMonitorReactivityBoard', () => {
  beforeEach(() => {
    storeMock.keepers.value = [
      keeper({ name: 'masc-improver', phase: 'Running', pipeline_stage: 'idle', last_activity_ago_s: 12, total_turns: 41 }),
      keeper({ name: 'nick0cave', phase: 'Paused', paused: true, pipeline_stage: 'paused', last_activity_ago_s: 1840, total_turns: 7 }),
    ]
    storeMock.shellRuntimeResolution.value = {
      status: 'ready',
      warnings: [],
      fleet_safety: {
        keeper_fibers: 2,
        paused_keepers: 1,
        keeper_reaction_ledger: null,
        keeper_fleet_safety: null,
        paused_keepers_health: {
          count: 1,
          names: ['nick0cave'],
          durable_count: 1,
          durable_names: ['nick0cave'],
          autoboot_enabled_count: 1,
          autoboot_enabled_names: ['nick0cave'],
          read_error_count: 0,
          read_errors: [],
          details: [{
            name: 'nick0cave',
            autoboot_enabled: true,
            pause_kind: 'blocked',
            paused_elapsed_sec: 265,
            missing_pause_root_cause: false,
          }],
        },
      },
    }
    keeperApiMock.fetchKeeperTransitions.mockResolvedValue({
      keeper: 'masc-improver',
      current_phase: 'Running',
      count: 1,
      transitions: [{
        prev_phase: 'Idle',
        new_phase: 'Running',
        selected_event: { type: 'wake' },
        event_type: 'wake · board mention',
        wall_clock_at_decision: 1_800_000_000,
        transition_outcome: 'ok',
      }],
    })
    keeperApiMock.fetchKeeperLifecycle.mockResolvedValue({
      keeper: 'masc-improver',
      count: 1,
      events: [{ ts: 1_800_000_000, event: 'started', phase: 'Running', detail: 'autoboot · slot 6' }],
    })
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('renders the health grid by default with pause indicator', async () => {
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)

    expect(container.querySelector('.tm-board')).toBeTruthy()
    expect(container.querySelectorAll('.ia-filter').length).toBe(4)

    await waitFor(() => {
      expect(container.textContent).toContain('masc-improver')
    })
    expect(container.textContent).toContain('Running')
    expect(container.textContent).toContain('12s 전')
    expect(container.textContent).toContain('41')
    expect(container.querySelector('.tm-pausedot')?.textContent).toContain('일시정지')
  })

  it('shows phase transitions timeline from keeper transitions API', async () => {
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)
    fireEvent.click(screen.getByText('상태 전환'))

    await waitFor(() => {
      expect(container.querySelector('.tm-time')).toBeTruthy()
    })
    const row = container.querySelector('.tm-time-row')
    expect(row?.textContent).toContain('masc-improver')
    expect(container.querySelector('.tm-tr')?.textContent).toContain('Idle')
    expect(container.querySelector('.tm-tr')?.textContent).toContain('Running')
    expect(row?.textContent).toContain('wake · board mention')
  })

  it('shows lifecycle events with tone badges from keeper lifecycle API', async () => {
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)
    fireEvent.click(screen.getByText('생명주기 이벤트'))

    await waitFor(() => {
      expect(container.querySelector('.tm-time')).toBeTruthy()
    })
    const badge = container.querySelector('.tm-time-row .ai-b')
    expect(badge?.textContent).toBe('기동됨')
    expect(container.textContent).toContain('autoboot · slot 6')
  })

  it('shows paused keeper cards with blocker detail from runtime sample', async () => {
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)
    fireEvent.click(screen.getByText('일시정지'))

    await waitFor(() => {
      expect(container.querySelector('.tm-paused-card')).toBeTruthy()
    })
    expect(container.textContent).toContain('⏸ nick0cave')
  })

  it('renders the all-clear treatment when no keeper is paused', async () => {
    storeMock.keepers.value = [keeper({ name: 'solo', phase: 'Running' })]
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)
    fireEvent.click(screen.getByText('일시정지'))

    await waitFor(() => {
      expect(container.querySelector('.tm-ok')).toBeTruthy()
    })
    expect(container.textContent).toContain('일시정지된 키퍼 없음')
  })

  it('renders dim empty text when no transitions are recorded', async () => {
    keeperApiMock.fetchKeeperTransitions.mockResolvedValue({
      keeper: 'solo',
      current_phase: 'Idle',
      count: 0,
      transitions: [],
    })
    storeMock.keepers.value = [keeper({ name: 'solo', phase: 'Offline' })]
    const { container } = render(html`<${ToolMonitorReactivityBoard} />`)
    fireEvent.click(screen.getByText('상태 전환'))

    await waitFor(() => {
      expect(container.textContent).toContain('기록된 상태 전환 없음')
    })
  })
})
