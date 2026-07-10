import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardBootstrap: vi.fn(),
  fetchDashboardShell: vi.fn(),
  fetchDashboardExecution: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
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
  fetchDashboardGoalsTree: apiMocks.fetchDashboardGoalsTree,
}))

vi.mock('./api/dashboard-execution', () => ({
  fetchDashboardExecution: apiMocks.fetchDashboardExecution,
}))

vi.mock('./api/dashboard-mission', () => ({
  fetchDashboardPlanning: apiMocks.fetchDashboardPlanning,
}))

vi.mock('./api/dashboard-goals', () => ({
  fetchDashboardGoalsTree: apiMocks.fetchDashboardGoalsTree,
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
        workspace_fsm: null,
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

  it('does not fetch the full goal tree during startup when bootstrap omits goals', async () => {
    apiMocks.fetchDashboardBootstrap.mockResolvedValue({
      served_at: '2026-06-26T00:00:00Z',
      milestone: 1,
      shell: {
        generated_at: '2026-06-26T00:00:00Z',
        status: { project: 'default' },
        counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
        configured_keepers: 0,
        providers: {},
        auth: null,
        config_resolution: null,
        runtime_resolution: null,
      },
      execution: {
        generated_at: '2026-06-26T00:00:00Z',
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
        generated_at: '2026-06-26T00:00:01Z',
        goals: [],
        rollup: {},
        workspace_fsm: null,
      },
      namespace_truth: {
        generated_at: '2026-06-26T00:00:02Z',
        root: {
          status: { project: 'default', version: '2.200.0' },
          counts: { agents: 0, tasks: 0, keepers: 0 },
          configured_keepers: 0,
          provenance: 'bootstrap',
        },
      },
      goal_loop_status: {
        generated_at: '2026-06-26T00:00:03Z',
        status: 'idle',
      },
    })

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshDashboard({ force: true })

    expect(apiMocks.fetchDashboardBootstrap).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchDashboardGoalsTree).not.toHaveBeenCalled()
    expect(goalTreeState.goalTreeData.value).toBeNull()
    expect(store.lastGoalsRefreshAt.value).toBe('2026-06-26T00:00:01Z')
  })

  it('hydrates the Goal Store tree when refreshing goals', async () => {
    apiMocks.fetchDashboardPlanning.mockResolvedValue({
      generated_at: '2026-06-25T00:00:00Z',
      goals: [],
      rollup: {},
      workspace_fsm: null,
    })
    apiMocks.fetchDashboardGoalsTree.mockResolvedValue({
      generated_at: '2026-06-25T00:00:01Z',
      tree: [],
      summary: { total_goals: 7, total_tasks: 124 },
    })

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshGoals()

    expect(apiMocks.fetchDashboardPlanning).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect(store.lastGoalsRefreshAt.value).toBe('2026-06-25T00:00:00Z')
    expect(goalTreeState.goalTreeData.value?.summary.total_tasks).toBe(124)
    expect(goalTreeState.goalTreeLoading.value).toBe(false)
  })

  it('drives goalTreeLoading while refreshGoals is in flight', async () => {
    apiMocks.fetchDashboardPlanning.mockResolvedValue({
      generated_at: '2026-06-25T00:00:00Z',
      goals: [],
      rollup: {},
      workspace_fsm: null,
    })
    const treePayload = { generated_at: '2026-06-25T00:00:01Z', tree: [], summary: { total_goals: 1 } }
    let resolveTree: (value: unknown) => void = () => {}
    apiMocks.fetchDashboardGoalsTree.mockImplementation(() => new Promise(resolve => {
      resolveTree = resolve
    }))

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    const refreshPromise = store.refreshGoals()
    await new Promise(r => setTimeout(r, 0))
    expect(goalTreeState.goalTreeLoading.value).toBe(true)
    resolveTree(treePayload)
    await refreshPromise
    expect(goalTreeState.goalTreeLoading.value).toBe(false)
  })

  it('surfaces a partial error when the Goal Store tree fetch fails and clears stale tree data', async () => {
    apiMocks.fetchDashboardPlanning.mockResolvedValue({
      generated_at: '2026-06-25T00:00:00Z',
      goals: [],
      rollup: {},
      workspace_fsm: null,
    })
    apiMocks.fetchDashboardGoalsTree.mockRejectedValue(new Error('tree offline'))

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshGoals()

    expect(goalTreeState.goalTreeData.value).toBeNull()
    expect(store.lastGoalsRefreshAt.value).toBeNull()
    expect(goalTreeState.goalTreeError.value).toContain('tree offline')
    expect(goalTreeState.goalTreeLoading.value).toBe(false)
    expect(toastMocks.showToast).toHaveBeenCalledWith(
      '목표 데이터를 일부 불러오지 못했습니다',
      'error',
      5000,
    )
  })

  it('clears goal tree data when the planning fetch fails even if Goal Store succeeds', async () => {
    apiMocks.fetchDashboardPlanning.mockRejectedValue(new Error('planning offline'))
    apiMocks.fetchDashboardGoalsTree.mockResolvedValue({
      generated_at: '2026-06-25T00:00:01Z',
      tree: [],
      summary: { total_goals: 1, active_goals: 1, total_tasks: 2 },
    })

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshGoals()

    expect(goalTreeState.goalTreeData.value).toBeNull()
    expect(store.lastGoalsRefreshAt.value).toBeNull()
    expect(goalTreeState.goalTreeError.value).toContain('planning offline')
    expect(goalTreeState.goalTreeLoading.value).toBe(false)
    expect(toastMocks.showToast).toHaveBeenCalledWith(
      '목표 데이터를 일부 불러오지 못했습니다',
      'error',
      5000,
    )
  })

  it('sets goalTreeError and clears stale data when the tree payload is malformed', async () => {
    apiMocks.fetchDashboardPlanning.mockResolvedValue({
      generated_at: '2026-06-25T00:00:00Z',
      goals: [],
      rollup: {},
      workspace_fsm: null,
    })
    apiMocks.fetchDashboardGoalsTree.mockResolvedValue({
      generated_at: '2026-06-25T00:00:01Z',
      tree: null,
      summary: { total_goals: 1, active_goals: 1, total_tasks: 2 },
    })

    const store = await import('./store')
    const goalTreeState = await import('./goal-tree-state')

    await store.refreshGoals()

    expect(goalTreeState.goalTreeData.value).toBeNull()
    expect(store.lastGoalsRefreshAt.value).toBeNull()
    expect(goalTreeState.goalTreeError.value).toBe('Goal Store tree payload was malformed')
    expect(goalTreeState.goalTreeLoading.value).toBe(false)
    expect(toastMocks.showToast).toHaveBeenCalledWith(
      '목표 데이터를 일부 불러오지 못했습니다',
      'error',
      5000,
    )
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

describe('refreshKeeperRuntimeStatus', () => {
  it('force-refreshes post-action runtime status by default', async () => {
    apiMocks.fetchDashboardShell.mockResolvedValue({
      generated_at: '2026-06-25T12:00:00Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 0, keepers: 1, total_runtimes: 1 },
      configured_keepers: 1,
      auth: null,
      config_resolution: null,
      runtime_resolution: null,
    })
    apiMocks.fetchDashboardExecution.mockResolvedValue({
      generated_at: '2026-06-25T12:00:00Z',
      status: { project: 'me' },
      agents: [],
      tasks: [],
      messages: [],
      keepers: [],
      execution_queue: [],
      worker_support_briefs: [],
      continuity_briefs: [],
    })

    const store = await import('./store')

    await store.refreshKeeperRuntimeStatus()

    expect(apiMocks.fetchDashboardExecution).toHaveBeenCalledWith({ force: true })
  })

  it('refreshes execution and light shell runtime status without full bootstrap', async () => {
    apiMocks.fetchDashboardShell.mockResolvedValue({
      generated_at: '2026-06-25T12:00:00Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 7, keepers: 1, total_runtimes: 1 },
      configured_keepers: 13,
      auth: null,
      config_resolution: null,
      runtime_resolution: {
        status: 'ready',
        warnings: [],
        base_path: { path: '/tmp/me', exists: true, source: 'input' },
        workspace_path: { path: '/tmp/me', exists: true, source: 'workspace' },
        resolved_base_path: { path: '/tmp/me', exists: true, source: 'resolved_base' },
        data_root: { path: '/tmp/me/.masc', exists: true, source: 'runtime_data' },
        prompt_markdown_dir: { path: '/tmp/me/.masc/config/prompts', exists: true, source: 'prompt_registry' },
        build: {
          release_version: '0.19.48',
          commit: 'abcdef1',
          started_at: '2026-06-25T11:59:00Z',
          uptime_seconds: 60,
        },
        keeper_fibers: 1,
        paused_keepers: 3,
        paused_keepers_health: { count: 3, names: ['a', 'b', 'c'] },
        keeper_fleet_safety: { running_keeper_fiber_count: 1, paused_keeper_count: 3 },
      },
    })
    apiMocks.fetchDashboardExecution.mockResolvedValue({
      generated_at: '2026-06-25T12:00:00Z',
      status: { project: 'me' },
      agents: [],
      tasks: [],
      messages: [],
      keepers: [{ name: 'verifier', status: 'running' }],
      execution_queue: [],
      worker_support_briefs: [],
      continuity_briefs: [],
    })

    const store = await import('./store')

    await store.refreshKeeperRuntimeStatus({ force: true })

    expect(apiMocks.fetchDashboardBootstrap).not.toHaveBeenCalled()
    expect(apiMocks.fetchDashboardExecution).toHaveBeenCalledWith({ force: true })
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledWith({ light: true })
    expect(apiMocks.fetchDashboardShell.mock.invocationCallOrder[0]!)
      .toBeLessThan(apiMocks.fetchDashboardExecution.mock.invocationCallOrder[0]!)
    expect(store.shellCounts.value).toEqual({
      agents: 0,
      tasks: 7,
      keepers: 1,
      total_runtimes: 1,
      configured_keepers: 13,
    })
    expect(store.shellRuntimeResolution.value?.fleet_safety?.paused_keepers).toBe(3)
    expect(store.keepers.value).toHaveLength(1)
  })
})
