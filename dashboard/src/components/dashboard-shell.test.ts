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

  it('surfaces a P0 blocked fleet when health reports zero running keeper fibers', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 14, configured_keepers: 14 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 0,
          paused_keepers: 13,
          keeper_fleet_no_fibers: true,
          keeper_fd_pressure: null,
          keeper_fleet_safety: {
            status: 'blocked',
            reason: null,
            blocker: 'no_running_fibers',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: 14,
            blocked_count: 14,
            bootable_keeper_count: 1,
            running_keeper_fiber_count: 0,
            healthy_running_keeper_fiber_count: 0,
            failing_keeper_fiber_count: 0,
            executable_keeper_fiber_count: 0,
            minimum_running_fibers: 1,
            no_running_fibers: true,
            no_executable_keeper_fibers: true,
            low_running_fiber_margin: false,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 14,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 14,
            paused_keeper_count: 13,
            autoboot_enabled_keeper_count: 14,
            paused_autoboot_enabled_keeper_count: 13,
            effective_reaction_capacity_count: 0,
            executable_reaction_capacity_count: 0,
            target_reaction_capacity_count: 14,
            operator_action_required: true,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'P0 fleet blocked',
      tone: 'bad',
    })])
    expect(chips[0]?.detail).toContain('status=blocked')
    expect(chips[0]?.detail).toContain('running_keeper_fiber_count=0')
    expect(chips[0]?.detail).toContain('paused_keeper_count=13')
    expect(chips[0]?.detail).toContain('target_reaction_capacity_count=14')
    expect(chips[0]?.detail).toContain('resume selected paused keepers')
  })

  it('labels an all-paused fleet as paused instead of blocked', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 3, configured_keepers: 3 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 0,
          paused_keepers: 3,
          keeper_fleet_no_fibers: true,
          keeper_fd_pressure: null,
          keeper_fleet_safety: {
            status: 'blocked',
            reason: null,
            blocker: 'no_executable_keeper_fibers',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: 3,
            blocked_count: 3,
            bootable_keeper_count: 3,
            running_keeper_fiber_count: 0,
            healthy_running_keeper_fiber_count: 0,
            failing_keeper_fiber_count: 0,
            executable_keeper_fiber_count: 0,
            minimum_running_fibers: 2,
            no_running_fibers: true,
            no_executable_keeper_fibers: true,
            low_running_fiber_margin: true,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 3,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 3,
            paused_keeper_count: 3,
            autoboot_enabled_keeper_count: 3,
            paused_autoboot_enabled_keeper_count: 3,
            effective_reaction_capacity_count: 0,
            executable_reaction_capacity_count: 0,
            target_reaction_capacity_count: 3,
            operator_action_required: true,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'Fleet paused',
      tone: 'warn',
    })])
    expect(chips[0]?.detail).toContain('paused_keeper_count=3')
    expect(chips[0]?.detail).toContain('paused is lifecycle state')
    expect(chips[0]?.detail).not.toContain('resume selected paused keepers')
  })

  it('surfaces fleet capacity degradation when running fibers are below target', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 13, configured_keepers: 13 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 3,
          paused_keepers: 2,
          keeper_fleet_no_fibers: false,
          keeper_fd_pressure: null,
          keeper_fleet_safety: {
            status: 'degraded',
            reason: null,
            blocker: 'reaction_capacity_below_target',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: 10,
            blocked_count: 10,
            bootable_keeper_count: 11,
            running_keeper_fiber_count: 3,
            healthy_running_keeper_fiber_count: 3,
            failing_keeper_fiber_count: 8,
            executable_keeper_fiber_count: 11,
            minimum_running_fibers: 2,
            no_running_fibers: false,
            no_executable_keeper_fibers: false,
            low_running_fiber_margin: false,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 10,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 2,
            paused_keeper_count: 2,
            autoboot_enabled_keeper_count: 13,
            paused_autoboot_enabled_keeper_count: 2,
            effective_reaction_capacity_count: 3,
            executable_reaction_capacity_count: 11,
            target_reaction_capacity_count: 13,
            operator_action_required: true,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'Fleet capacity degraded',
      tone: 'warn',
    })])
    expect(chips[0]?.detail).toContain('status=degraded')
    expect(chips[0]?.detail).toContain('healthy_running_keeper_fiber_count=3')
    expect(chips[0]?.detail).toContain('executable_keeper_fiber_count=11')
    expect(chips[0]?.detail).toContain('failing_keeper_fiber_count=8')
    expect(chips[0]?.detail).toContain('target_reaction_capacity_count=13')
    expect(chips[0]?.detail).toContain('reaction_capacity_shortfall_count=10')
    expect(chips[0]?.detail).toContain('blocker=reaction_capacity_below_target')
  })

  it('does not treat non-FD fleet blocked counts as FD pressure', () => {
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
          keeper_fleet_no_fibers: false,
          keeper_fd_pressure: null,
          keeper_fleet_safety: {
            status: 'degraded',
            reason: null,
            blocker: 'reaction_capacity_below_target',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: 24,
            blocked_count: 24,
            bootable_keeper_count: 24,
            running_keeper_fiber_count: 8,
            healthy_running_keeper_fiber_count: 8,
            failing_keeper_fiber_count: 0,
            executable_keeper_fiber_count: 8,
            minimum_running_fibers: 2,
            no_running_fibers: false,
            no_executable_keeper_fibers: false,
            low_running_fiber_margin: false,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 16,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 16,
            paused_keeper_count: 0,
            autoboot_enabled_keeper_count: 24,
            paused_autoboot_enabled_keeper_count: 0,
            effective_reaction_capacity_count: 8,
            executable_reaction_capacity_count: 8,
            target_reaction_capacity_count: 24,
            operator_action_required: true,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'fleet-liveness-risk',
      label: 'Fleet capacity degraded',
      tone: 'warn',
    })])
    expect(chips[0]?.detail).not.toContain('FD pressure')
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

  it('prioritizes FD pressure over degraded capacity when both are present', () => {
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
          keeper_fleet_no_fibers: false,
          keeper_fd_pressure: {
            status: 'blocked',
            reason: 'fd_pressure',
            admission_blocked: true,
            admission_blocked_keepers: 24,
            blocked_keepers: null,
            blocked_count: null,
          },
          keeper_fleet_safety: {
            status: 'degraded',
            reason: null,
            blocker: 'reaction_capacity_below_target',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: null,
            blocked_count: null,
            bootable_keeper_count: 24,
            running_keeper_fiber_count: 8,
            healthy_running_keeper_fiber_count: 8,
            failing_keeper_fiber_count: 0,
            executable_keeper_fiber_count: 8,
            minimum_running_fibers: 2,
            no_running_fibers: false,
            no_executable_keeper_fibers: false,
            low_running_fiber_margin: false,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 16,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 16,
            paused_keeper_count: 0,
            autoboot_enabled_keeper_count: 24,
            paused_autoboot_enabled_keeper_count: 0,
            effective_reaction_capacity_count: 8,
            executable_reaction_capacity_count: 8,
            target_reaction_capacity_count: 24,
            operator_action_required: true,
          },
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

  it('surfaces reaction ledger cursor sweeps even when pending backlog is clear', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: null,
          paused_keepers: null,
          keeper_fleet_no_fibers: null,
          keeper_fd_pressure: null,
          keeper_fleet_safety: null,
          keeper_reaction_ledger: {
            status: 'ok',
            operator_action_required: false,
            cursor_ack_count: 4,
            cursor_swept_stimulus_count: 3,
            legacy_cursor_swept_stimulus_count: 1,
            pending_stimulus_count: 0,
            read_error_count: 0,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'reaction-ledger',
      label: 'Reaction ledger swept 4',
      tone: 'ok',
    })])
    expect(chips[0]?.detail).toContain('cursor_swept=3')
    expect(chips[0]?.detail).toContain('legacy_swept=1')
  })

  it('warns on real reaction ledger pending backlog', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: null,
          paused_keepers: null,
          keeper_fleet_no_fibers: null,
          keeper_fd_pressure: null,
          keeper_fleet_safety: null,
          keeper_reaction_ledger: {
            status: 'degraded',
            operator_action_required: true,
            cursor_ack_count: 4,
            cursor_swept_stimulus_count: 3,
            legacy_cursor_swept_stimulus_count: 1,
            pending_stimulus_count: 2,
            read_error_count: 0,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips).toEqual([expect.objectContaining({
      key: 'reaction-ledger',
      label: 'Reaction ledger pending 2',
      tone: 'warn',
    })])
    expect(chips[0]?.detail).toContain('pending=2')
  })
})
