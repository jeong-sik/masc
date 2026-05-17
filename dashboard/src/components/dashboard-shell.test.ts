// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { DashboardMain, dashboardHealthChips } from './dashboard-shell'
import { route } from '../router'
import { connected } from '../sse'
import { dashboardLoading } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'

describe('DashboardMain solo mode', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    dashboardLoading.value = false
    connected.value = true
    namespaceTruthInitializing.value = false
    document.title = 'MASC Dashboard'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('keeps document title and active observability filters visible in solo mode', async () => {
    route.value = {
      tab: 'monitoring',
      params: {
        section: 'runtime',
        view: 'cost',
        solo: '1',
        keeper: 'keeper-alpha',
        range: '1h',
      },
      postId: null,
    }

    render(h(DashboardMain, {}), container)

    await waitFor(() => expect(document.title).toBe('MASC · Live Runtime'))
    expect(container.querySelector('[data-testid="dashboard-widget-solo-bar"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Active observability filters"]')).not.toBeNull()
  })
})

describe('dashboardHealthChips', () => {
  it('separates source mismatch, paused keepers, and execution errors', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 1, configured_keepers: 2 },
      keepers: [{
        name: 'keeper-a',
        status: 'paused',
        paused: true,
      } as any],
      runtimeResolution: {
        status: 'warn',
        warnings: [],
        source_mismatch: true,
        server_workspace_mismatch: false,
      } as any,
      executionError: 'snapshot failed',
      loading: false,
    })

    expect(chips.map(chip => chip.key)).toEqual([
      'source-mismatch',
      'paused-keepers',
      'execution-error',
    ])
  })

  it('returns a healthy chip when no runtime risk is visible', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: null,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'runtime-ok',
      tone: 'ok',
    })])
  })

  it('surfaces fleet liveness risk when health shows stalled fibers with paused keepers', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 1,
          paused_keepers: 3,
          keeper_fleet_no_fibers: null,
          keeper_fd_pressure: null,
          keeper_fleet_safety: null,
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'Fleet liveness risk',
      tone: 'bad',
    })])
    expect(chips[0]?.detail).toContain('keeper_fibers=1')
  })

  it('surfaces fleet liveness risk when FD pressure blocks 24 keepers', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 24, configured_keepers: 24 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 8,
          paused_keepers: 0,
          keeper_fleet_no_fibers: null,
          keeper_fd_pressure: {
            status: 'blocked',
            reason: 'fd_pressure',
            admission_blocked: true,
            admission_blocked_keepers: 24,
            blocked_keepers: null,
            blocked_count: null,
          },
          keeper_fleet_safety: null,
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'Fleet liveness risk',
      tone: 'bad',
    })])
    expect(chips[0]?.detail).toContain('blocking 24 keepers')
  })
})
