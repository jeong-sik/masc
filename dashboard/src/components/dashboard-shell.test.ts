// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { DashboardHealthStrip, DashboardMain, dashboardHealthChips, isKeeperDetailDashboardRoute, SideRail } from './dashboard-shell'
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

    await waitFor(() => expect(document.title).toBe('MASC · Runtime'))
    expect(container.querySelector('[data-testid="dashboard-widget-solo-bar"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Active observability filters"]')).not.toBeNull()
  })
})

describe('isKeeperDetailDashboardRoute', () => {
  it('detects monitor keeper detail drilldowns', () => {
    expect(isKeeperDetailDashboardRoute({
      tab: 'monitoring',
      params: { section: 'agents', keeper: 'sangsu' },
      postId: null,
    })).toBe(true)
  })

  it('treats the top-level keepers surface as an immersive keeper workspace', () => {
    expect(isKeeperDetailDashboardRoute({
      tab: 'keepers',
      params: {},
      postId: null,
    })).toBe(true)
  })

  it('does not treat the fleet list as keeper detail', () => {
    expect(isKeeperDetailDashboardRoute({
      tab: 'monitoring',
      params: { section: 'agents' },
      postId: null,
    })).toBe(false)
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
      'keeper-count-basis',
      'paused-keepers',
      'execution-error',
    ])
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.label)
      .toBe('키퍼 런타임 가동 1 / 일시정지 1 / 설정 2')
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.detail)
      .toBe('런타임 가동=shell; 일시정지=재개 대기 lifecycle row; 오프라인=프로세스/하트비트 없음으로 기동 필요 row; 설정=shell keeper 설정.')
    expect(chips.find(chip => chip.key === 'paused-keepers')?.label)
      .toBe('일시정지 keeper 1')
    expect(chips.find(chip => chip.key === 'paused-keepers')?.detail)
      .toBe('재개 대기 상태의 keeper가 있습니다. board/tool 활동은 조용해 보일 수 있습니다.')
  })

  it('does not label an intentional server/base split as data source mismatch', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 1, configured_keepers: 1 },
      keepers: [{ name: 'keeper-a', status: 'running' } as any],
      runtimeResolution: {
        status: 'warn',
        warnings: [],
        source_mismatch: false,
        server_workspace_mismatch: true,
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips.find(chip => chip.key === 'source-mismatch')).toBeUndefined()
    expect(chips).toContainEqual(expect.objectContaining({
      key: 'server-workspace-split',
      label: 'Server/base split',
      tone: 'muted',
      route: { tab: 'monitoring', params: { section: 'runtime' } },
    }))
  })

  it('promotes runtime provider probe failures into a routed health chip', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 1, configured_keepers: 1 },
      keepers: [{ name: 'keeper-a', status: 'running' } as any],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        source_mismatch: false,
        server_workspace_mismatch: false,
      } as any,
      runtimeProviderProbe: {
        status: 'unreachable',
        summary: {
          runtimes: 1,
          probed: 1,
          reachable: 0,
          failed: 1,
          skipped: 0,
          default_runtime_id: 'runpod_mtp.qwen',
        },
        providers: [{
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          status: 'missing_auth',
          reachable: false,
          credential_required: true,
          auth_present: false,
        }],
      },
      executionError: null,
      loading: false,
    })

    expect(chips).toContainEqual(expect.objectContaining({
      key: 'runtime-provider-health',
      label: 'Runtime auth missing 1',
      tone: 'bad',
      detail: 'default=runpod_mtp.qwen, reachable=0, failed=1, skipped=0, providers=runpod_mtp.qwen: missing_auth',
      route: { tab: 'monitoring', params: { section: 'runtime', view: 'providers' } },
    }))
  })

  it('surfaces runtime probe fetch failures when provider status is unavailable', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 1, configured_keepers: 1 },
      keepers: [{ name: 'keeper-a', status: 'running' } as any],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        source_mismatch: false,
        server_workspace_mismatch: false,
      } as any,
      runtimeProviderProbe: null,
      runtimeProviderProbeError: 'runtime probe fetch failed: 503',
      executionError: null,
      loading: false,
    })

    expect(chips).toContainEqual(expect.objectContaining({
      key: 'runtime-probe-unavailable',
      label: 'Runtime probe unavailable',
      tone: 'warn',
      detail: 'runtime probe fetch failed: 503',
      route: { tab: 'monitoring', params: { section: 'runtime', view: 'providers' } },
    }))
  })

  it('uses namespace truth as the configured keeper count authority in health chips', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { agents: 0, keepers: 2, configured_keepers: 2 },
      namespaceTruthCounts: { agents: 0, keepers: 16, tasks: 0, total_runtimes: 16 },
      namespaceTruthConfiguredKeepers: 16,
      keepers: [],
      runtimeResolution: null,
      executionError: null,
      loading: false,
    })

    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.label)
      .toBe('키퍼 런타임 가동 2 / 설정 16')
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.detail)
      .toBe('런타임 가동=shell; 일시정지=재개 대기 lifecycle row; 오프라인=프로세스/하트비트 없음으로 기동 필요 row; 설정=project snapshot keeper 설정.')
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

  it('keeps mixed paused fleets blocked when autoboot keepers are still below target', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 16, configured_keepers: 16 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 0,
          paused_keepers: 14,
          keeper_fleet_no_fibers: true,
          keeper_fd_pressure: null,
          keeper_fleet_safety: {
            status: 'blocked',
            reason: null,
            blocker: 'no_executable_keeper_fibers',
            admission_blocked: null,
            admission_blocked_keepers: null,
            blocked_keepers: 16,
            blocked_count: 16,
            bootable_keeper_count: 2,
            running_keeper_fiber_count: 0,
            healthy_running_keeper_fiber_count: 0,
            failing_keeper_fiber_count: 0,
            executable_keeper_fiber_count: 0,
            minimum_running_fibers: 2,
            no_running_fibers: true,
            no_executable_keeper_fibers: true,
            low_running_fiber_margin: true,
            reaction_capacity_below_target: true,
            reaction_capacity_shortfall_count: 14,
            executable_reaction_capacity_below_target: true,
            executable_reaction_capacity_shortfall_count: 14,
            paused_keeper_count: 14,
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
    expect(chips[0]?.detail).toContain('paused_autoboot_enabled_keeper_count=13')
    expect(chips[0]?.detail).toContain('resume selected paused keepers')
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

  it('attaches drill-down routes so HEALTH chips deep-link operators to the right view', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 0, configured_keepers: 3 },
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
      executionError: null,
      loading: false,
    })

    const byKey = Object.fromEntries(chips.map(c => [c.key, c]))

    // source-mismatch → runtime resolution view
    expect(byKey['source-mismatch']?.route).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime' },
    })
    // paused-keepers → fleet-health (operator drills into the keeper list)
    expect(byKey['paused-keepers']?.route).toEqual({
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    })
    // no-keeper-rows → same fleet-health section (configured vs live diff)
    expect(byKey['no-keeper-rows']?.route).toEqual({
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    })
  })

  it('leaves transport-offline and execution-error without routes (no useful drill-down)', () => {
    const chips = dashboardHealthChips({
      connected: false,
      counts: null,
      keepers: [],
      runtimeResolution: null,
      executionError: 'snapshot failed',
      loading: false,
    })

    const byKey = Object.fromEntries(chips.map(c => [c.key, c]))
    expect(byKey['transport-offline']?.route).toBeUndefined()
    expect(byKey['execution-error']?.route).toBeUndefined()
  })

  it('routes the reaction-ledger chip to the reactivity monitor view', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_reaction_ledger: {
            status: 'degraded',
            pending_stimulus_count: 2,
            cursor_swept_stimulus_count: 0,
            legacy_cursor_swept_stimulus_count: 0,
            read_error_count: 0,
            cursor_ack_count: 5,
            operator_action_required: false,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    const ledger = chips.find(c => c.key === 'reaction-ledger')
    expect(ledger?.route).toEqual({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'keeper-health' },
    })
  })

  it('surfaces CDAL proof and task-scope blockers as a routed health chip', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 2, configured_keepers: 2 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: null,
        cdal: {
          writer_status: 'proof_store_incomplete',
          operator_action_required: true,
          proof_store_path_drift: false,
          proof_store: {
            status: 'stale_incomplete_runs',
            completeness: {
              incomplete_run_dirs: 6,
              stale_incomplete_run_dirs: 3,
              terminal_incomplete_run_dirs: 1,
            },
          },
          task_scope: {
            status: 'partial_task_scope',
            current_writer_missing_task_scope_rows: 5,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    const cdal = chips.find(c => c.key === 'cdal-runtime-health')
    expect(cdal).toMatchObject({
      label: 'CDAL proof incomplete 6',
      tone: 'bad',
      route: {
        tab: 'monitoring',
        params: { section: 'fleet-health' },
      },
    })
    expect(cdal?.detail).toContain('stale=3')
    expect(cdal?.detail).toContain('current_missing_task_scope=5')
  })
})

describe('SideRail v2 chrome', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = {
      tab: 'workspace',
      params: { section: 'work' },
      postId: null,
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders v2 structural classes and highlights the active surface', () => {
    render(h(SideRail, { collapsed: false, onToggle: () => {} }), container)

    expect(container.querySelector('.nav-brand')).not.toBeNull()
    expect(container.querySelector('.nav-sec')).not.toBeNull()
    expect(container.querySelector('.nav-link.active')).not.toBeNull()
    expect(container.querySelector('.nav-link.active')?.textContent).toContain('Work')

    const sublist = container.querySelector('.nav-sublist')
    expect(sublist).not.toBeNull()
    const activeSublink = sublist?.querySelector('.nav-sublink.active')
    expect(activeSublink).not.toBeNull()
    expect(activeSublink?.textContent).toContain('Work')
  })

  it('renders collapsed icon-only links with v2 classes', () => {
    render(h(SideRail, { collapsed: true, onToggle: () => {} }), container)

    const links = container.querySelectorAll('.nav-link-collapsed')
    expect(links.length).toBeGreaterThan(0)
    expect(container.querySelector('.nav-link-collapsed.active')).not.toBeNull()
  })
})

describe('DashboardHealthStrip v2 chrome', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.resolve(new Response('{}'))),
    )
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
  })

  it('renders with the v2-health-strip marker class', () => {
    render(h(DashboardHealthStrip, {}), container)

    const strip = container.querySelector('[data-testid="dashboard-health-strip"]')
    expect(strip).not.toBeNull()
    expect(strip?.classList.contains('v2-health-strip')).toBe(true)
  })
})
