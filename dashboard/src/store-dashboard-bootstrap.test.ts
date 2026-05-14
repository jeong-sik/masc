import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardBootstrap: vi.fn(),
  fetchDashboardShell: vi.fn(),
  fetchDashboardExecution: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
}))

const toastMocks = vi.hoisted(() => ({
  showToast: vi.fn(),
}))

vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardBootstrap: apiMocks.fetchDashboardBootstrap,
  fetchDashboardShell: apiMocks.fetchDashboardShell,
}))

vi.mock('./api/dashboard', () => ({
  fetchDashboardExecution: apiMocks.fetchDashboardExecution,
  fetchDashboardPlanning: apiMocks.fetchDashboardPlanning,
}))

vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))

vi.mock('./components/common/toast', () => ({
  showToast: toastMocks.showToast,
}))

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('refreshDashboard bootstrap', () => {
  it('hydrates startup dashboard slices from the bootstrap aggregator', async () => {
    apiMocks.fetchDashboardBootstrap.mockResolvedValue({
      served_at: '2026-05-14T06:00:00Z',
      milestone: 1,
      shell: {
        generated_at: '2026-05-14T06:00:00Z',
        status: { project: 'default' },
        counts: { agents: 1, tasks: 2, keepers: 3, total_runtimes: 4 },
        configured_keepers: 5,
        providers: {},
        meta_cognition: null,
        auth: null,
        config_resolution: null,
        runtime_resolution: null,
      },
      execution: {
        generated_at: '2026-05-14T06:00:00Z',
        status: { project: 'default' },
        agents: [],
        tasks: [],
        messages: [],
        keepers: [],
        execution_queue: [],
        worker_support_briefs: [],
        continuity_briefs: [],
      },
      planning: {
        generated_at: '2026-05-14T06:00:01Z',
        goals: [],
        rollup: {},
        coordination_fsm: null,
      },
      namespace_truth: {
        generated_at: '2026-05-14T06:00:02Z',
        root: {
          status: { project: 'default', version: '2.200.0' },
          counts: { agents: 1, tasks: 2, keepers: 3 },
          configured_keepers: 5,
          provenance: 'bootstrap',
        },
      },
      goals: {
        generated_at: '2026-05-14T06:00:03Z',
        tree: [],
        summary: { total_goals: 0 },
      },
    })

    const store = await import('./store')
    const namespaceStore = await import('./namespace-truth-store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshDashboard({ force: true })

    expect(apiMocks.fetchDashboardBootstrap).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchDashboardShell).not.toHaveBeenCalled()
    expect(apiMocks.fetchDashboardExecution).not.toHaveBeenCalled()
    expect(store.shellCounts.value).toEqual({
      agents: 1,
      tasks: 2,
      keepers: 3,
      total_runtimes: 4,
      configured_keepers: 5,
    })
    expect(store.executionLoaded.value).toBe(true)
    expect(store.lastGoalsRefreshAt.value).toBe('2026-05-14T06:00:01Z')
    expect(namespaceStore.namespaceTruth.value?.root.provenance).toBe('bootstrap')
    expect(store.serverStatus.value?.version).toBe('2.200.0')
    expect(goalTreeState.goalTreeData.value?.summary.total_goals).toBe(0)
  })

  it('falls back to legacy shell and execution fetches when a required bootstrap slice is unavailable', async () => {
    apiMocks.fetchDashboardBootstrap.mockResolvedValue({
      served_at: '2026-05-14T06:00:00Z',
      milestone: 1,
      shell: { error: 'slice_unavailable', slice: 'shell' },
      execution: { error: 'slice_unavailable', slice: 'execution' },
    })
    apiMocks.fetchDashboardShell.mockResolvedValue({
      generated_at: '2026-05-14T06:01:00Z',
      status: { project: 'fallback' },
      counts: { agents: 0, tasks: 1, keepers: 0 },
      providers: {},
      meta_cognition: null,
      auth: null,
      config_resolution: null,
      runtime_resolution: null,
    })
    apiMocks.fetchDashboardExecution.mockResolvedValue({
      generated_at: '2026-05-14T06:01:00Z',
      status: { project: 'fallback' },
      agents: [],
      tasks: [],
      messages: [],
      keepers: [],
      execution_queue: [],
      worker_support_briefs: [],
      continuity_briefs: [],
    })

    const store = await import('./store')

    await store.refreshDashboard({ force: true })

    expect(apiMocks.fetchDashboardBootstrap).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledWith({ light: false })
    expect(apiMocks.fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(store.serverStatus.value?.project).toBe('fallback')
    expect(store.executionLoaded.value).toBe(true)
  })
})
