import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardBootstrap: vi.fn(),
  fetchDashboardShell: vi.fn(),
  fetchDashboardExecution: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
}))

const toastMocks = vi.hoisted(() => ({ showToast: vi.fn() }))

vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardBootstrap: apiMocks.fetchDashboardBootstrap,
  fetchDashboardShell: apiMocks.fetchDashboardShell,
}))

vi.mock('./api/dashboard', () => ({
  fetchDashboardExecution: apiMocks.fetchDashboardExecution,
  fetchDashboardPlanning: apiMocks.fetchDashboardPlanning,
}))

vi.mock('./api/dashboard-execution', () => ({
  fetchDashboardExecution: apiMocks.fetchDashboardExecution,
}))

vi.mock('./api/dashboard-mission', () => ({
  fetchDashboardPlanning: apiMocks.fetchDashboardPlanning,
}))

vi.mock('./sse', () => ({ journal: { log: vi.fn() } }))
vi.mock('./components/common/toast', () => ({ showToast: toastMocks.showToast }))

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

const bootstrapPayload = {
  served_at: '2026-07-15T00:00:00Z',
  milestone: 1,
  shell: {
    generated_at: '2026-07-15T00:00:00Z',
    status: { project: 'default' },
    counts: { agents: 1, tasks: 2, keepers: 3, total_runtimes: 4 },
    configured_keepers: 5,
    providers: {},
    auth: null,
    config_resolution: null,
    runtime_resolution: null,
  },
  execution: {
    generated_at: '2026-07-15T00:00:00Z',
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
    generated_at: '2026-07-15T00:00:01Z',
    task_backlog: { todo: 2, claimed: 0, in_progress: 0, done: 0, cancelled: 0 },
    workspace_fsm: null,
  },
  namespace_truth: {
    generated_at: '2026-07-15T00:00:02Z',
    root: {
      status: { project: 'default', version: '2.200.0' },
      counts: { agents: 1, tasks: 2, keepers: 3 },
      configured_keepers: 5,
      provenance: 'bootstrap',
    },
  },
}

describe('dashboard bootstrap and planning refresh', () => {
  it('hydrates task-only planning from the bootstrap aggregator', async () => {
    apiMocks.fetchDashboardBootstrap.mockResolvedValue(bootstrapPayload)
    const store = await import('./store')
    const namespaceStore = await import('./namespace-truth-store')

    await store.refreshDashboard({ force: true })

    expect(apiMocks.fetchDashboardBootstrap).toHaveBeenCalledTimes(1)
    expect(apiMocks.fetchDashboardShell).not.toHaveBeenCalled()
    expect(apiMocks.fetchDashboardExecution).not.toHaveBeenCalled()
    expect(store.lastPlanningRefreshAt.value).toBe('2026-07-15T00:00:01Z')
    expect(namespaceStore.namespaceTruth.value?.root.provenance).toBe('bootstrap')
  })

  it('refreshes planning through its single endpoint', async () => {
    apiMocks.fetchDashboardPlanning.mockResolvedValue({
      generated_at: '2026-07-15T01:00:00Z',
      task_backlog: { todo: 1, claimed: 1, in_progress: 0, done: 0, cancelled: 0 },
      workspace_fsm: null,
    })
    const store = await import('./store')

    await store.refreshPlanning()

    expect(apiMocks.fetchDashboardPlanning).toHaveBeenCalledTimes(1)
    expect(store.lastPlanningRefreshAt.value).toBe('2026-07-15T01:00:00Z')
    expect(store.planningLoading.value).toBe(false)
    expect(store.planningError.value).toBeNull()
  })
})
