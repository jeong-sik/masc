// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { ConnectionStatus, DashboardHealthStrip, DashboardMain, dashboardHealthChips, isKeeperDetailDashboardRoute, shouldRenderSurfaceLead } from './dashboard-shell'
import { route } from '../router'
import { dashboardWsConnected, dashboardWsLastError, dashboardWsReady } from '../dashboard-ws-state'
import { dashboardLoading } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'

describe('DashboardMain solo mode', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    dashboardLoading.value = false
    dashboardWsConnected.value = true
    dashboardWsReady.value = true
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

describe('DashboardMain primary heading', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    dashboardLoading.value = false
    dashboardWsConnected.value = true
    dashboardWsReady.value = true
    namespaceTruthInitializing.value = false
    document.title = 'MASC Dashboard'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders a bespoke-header surface with one h1 and no generic lead h1', async () => {
    route.value = { tab: 'overview', params: {}, postId: null }

    render(h(DashboardMain, {}), container)

    await waitFor(() => {
      expect([...container.querySelectorAll('h1')].map(node => node.textContent?.trim()))
        .toEqual(['지금, 전체'])
    }, { timeout: 5000 })
    expect(container.querySelector('.v2-surface-header h1')).toBeNull()
  })
})

describe('ConnectionStatus', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastError.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastError.value = null
  })

  it('uses WS readiness as the connection signal', () => {
    dashboardWsConnected.value = true
    dashboardWsReady.value = true

    render(h(ConnectionStatus, {}), container)

    expect(container.textContent).toContain('Connected')
    expect(container.textContent).not.toContain('Reconnecting')
  })

  it('shows handshaking instead of reconnecting while the WS hello is pending', () => {
    dashboardWsConnected.value = true
    dashboardWsReady.value = false

    render(h(ConnectionStatus, {}), container)

    expect(container.textContent).toContain('Connecting WS')
    expect(container.textContent).not.toContain('Reconnecting')
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
      .toBe('keeper 실행 fiber 1 / 일시정지 keeper 1 / configured keeper 2')
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.detail)
      .toBe('keeper 실행 fiber=shell; 일시정지 keeper=일시정지 lifecycle row; 중지 keeper=프로세스/하트비트 없음으로 기동 필요 row; configured keeper=shell keeper 설정.')
    expect(chips.find(chip => chip.key === 'paused-keepers')?.label)
      .toBe('일시정지 keeper 1')
    expect(chips.find(chip => chip.key === 'paused-keepers')?.detail)
      .toBe('일시정지 상태의 keeper가 있습니다. board/tool 활동은 조용해 보일 수 있습니다.')
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
        source: 'runtime.toml',
        status: 'unreachable',
        probe_ok: false,
        checked_at: '2026-08-24T12:00:00Z',
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
          provider_display_name: 'RunPod MTP',
          model_id: 'qwen',
          model_api_name: 'Qwen/Qwen3-32B',
          protocol: 'openai-compatible-http',
          runtime_kind: 'http',
          transport: 'http',
          auth_kind: 'env:RUNPOD_API_KEY',
          status: 'missing_auth',
          reachable: false,
          http_status: null,
          latency_ms: null,
          model_count: null,
          content_type: null,
          downloaded_bytes: null,
          endpoint_url: 'https://example.invalid/v1',
          probe_url: 'https://example.invalid/v1/models',
          error: 'env credential RUNPOD_API_KEY is empty or unset',
          checked_at: '2026-08-24T12:00:00Z',
          credential_required: true,
          auth_present: false,
        }],
        errors: ['runpod_mtp.qwen: missing_auth'],
        observations: ['runtime.toml provider reachability: 0 reachable, 1 failed, 0 skipped'],
        limitations: ['Probe checks provider metadata endpoints only; it does not send a completion request.'],
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
      .toBe('keeper 실행 fiber 2 / configured keeper 16')
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.detail)
      .toBe('keeper 실행 fiber=shell; 일시정지 keeper=일시정지 lifecycle row; 중지 keeper=프로세스/하트비트 없음으로 기동 필요 row; configured keeper=project snapshot keeper 설정.')
  })

  it('uses runtime health as the paused keeper count authority when detail rows are absent', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { agents: 0, keepers: 9, configured_keepers: 13, total_runtimes: 13 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        source_mismatch: false,
        server_workspace_mismatch: false,
        fleet_safety: {
          keeper_fibers: 9,
          paused_keepers: 2,
          paused_keepers_health: { count: 3 },
          keeper_fleet_safety: {
            executable_keeper_fiber_count: 0,
            paused_keeper_count: 4,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.label)
      .toBe('keeper 실행 fiber 0 / 일시정지 keeper 3 / configured keeper 13')
    expect(chips.find(chip => chip.key === 'keeper-count-basis')?.detail)
      .toBe('keeper 실행 fiber=runtime health; 일시정지 keeper=runtime health; 중지 keeper=runtime health only; execution offline rows not mixed; configured keeper=shell keeper 설정.')
    expect(chips.find(chip => chip.key === 'paused-keepers')?.label)
      .toBe('일시정지 keeper 3')
    expect(chips.find(chip => chip.key === 'no-keeper-rows')).toBeUndefined()
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









  it('surfaces quarantined reaction ledger rows even when pending backlog is clear', () => {
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
          keeper_fleet_safety: null,
          keeper_reaction_ledger: {
            status: 'ok',
            operator_action_required: false,
            cursor_swept_stimulus_count: 3,
            quarantined_row_count: 1,
            pending_stimulus_count: 0,
            read_error_count: 0,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    const chip = chips.find(c => c.key === 'reaction-ledger')
    expect(chip).toEqual(expect.objectContaining({
      label: 'Reaction ledger quarantined 1',
      tone: 'warn',
    }))
    expect(chip?.detail).toContain('cursor_swept=3')
    expect(chip?.detail).toContain('quarantined=1')
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
          keeper_fleet_safety: null,
          keeper_reaction_ledger: {
            status: 'degraded',
            operator_action_required: true,
            cursor_swept_stimulus_count: 3,
            quarantined_row_count: 1,
            pending_stimulus_count: 2,
            read_error_count: 0,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })

    const chip = chips.find(c => c.key === 'reaction-ledger')
    expect(chip).toEqual(expect.objectContaining({
      label: 'Reaction ledger pending 2',
      tone: 'warn',
    }))
    expect(chip?.detail).toContain('pending=2')
  })

  it('attaches drill-down routes so HEALTH chips deep-link operators to the right view', () => {
    const chips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 0, configured_keepers: 3 },
      keepers: [],
      runtimeResolution: {
        status: 'warn',
        warnings: [],
        source_mismatch: true,
        server_workspace_mismatch: false,
        fleet_safety: {
          keeper_fibers: 0,
          paused_keepers: 0,
          paused_keepers_health: null,
          keeper_fleet_safety: null,
        },
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
    // no-keeper-rows → same fleet-health section (configured vs live diff)
    expect(byKey['no-keeper-rows']?.route).toEqual({
      tab: 'monitoring',
      params: { section: 'fleet-health' },
    })

    const pausedChips = dashboardHealthChips({
      connected: true,
      counts: { keepers: 0, configured_keepers: 3 },
      keepers: [],
      runtimeResolution: {
        status: 'ready',
        warnings: [],
        fleet_safety: {
          keeper_fibers: 0,
          paused_keepers: 1,
          keeper_fleet_safety: {
            status: 'blocked',
            executable_keeper_fiber_count: 0,
            paused_keeper_count: 1,
          },
        },
      } as any,
      executionError: null,
      loading: false,
    })
    const pausedByKey = Object.fromEntries(pausedChips.map(c => [c.key, c]))
    // paused-keepers → fleet-health (operator drills into the keeper list)
    expect(pausedByKey['paused-keepers']?.route).toEqual({
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
            quarantined_row_count: 0,
            read_error_count: 0,
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
    render(h(DashboardHealthStrip, { hidden: false }), container)

    const strip = container.querySelector('[data-testid="dashboard-health-strip"]')
    expect(strip).not.toBeNull()
    expect(strip?.classList.contains('v2-health-strip')).toBe(true)
  })
})

describe('shouldRenderSurfaceLead', () => {
  afterEach(() => {
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  // Surfaces that render the shared SurfaceHeader in their own body must NOT
  // also get the generic SurfaceLead — otherwise the title renders twice.
  // board regressed in #22021; monitoring/command/lab carried the same gap.
  it.each(['monitoring', 'command', 'lab', 'board'] as const)(
    'suppresses the generic SurfaceLead for the %s surface (renders its own SurfaceHeader)',
    tab => {
      expect(shouldRenderSurfaceLead({ tab, params: {}, postId: null })).toBe(false)
    },
  )

  // code (IDE) has no bespoke header and is not a keeper-detail route, so it
  // still relies on the generic SurfaceLead — a control that the set was not
  // broadened to suppress the lead everywhere.
  it('keeps the generic SurfaceLead for the code surface', () => {
    expect(shouldRenderSurfaceLead({ tab: 'code', params: {}, postId: null })).toBe(true)
  })

  // keepers always renders its own keeper UI (keeper-detail guard short-circuits
  // before the set lookup), so it never gets the generic lead.
  it('suppresses the generic SurfaceLead for the keepers surface via the keeper-detail guard', () => {
    expect(shouldRenderSurfaceLead({ tab: 'keepers', params: {}, postId: null })).toBe(false)
  })
})
