import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardNamespaceTruth: vi.fn(),
  fetchDashboardShell: vi.fn(),
  fetchDashboardExecution: vi.fn(),
  fetchDashboardMemory: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
}))

vi.mock('./api', () => apiMocks)
vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardNamespaceTruth: apiMocks.fetchDashboardNamespaceTruth,
  fetchDashboardShell: apiMocks.fetchDashboardShell,
}))
vi.mock('./api/dashboard', () => ({
  fetchDashboardNamespaceTruth: apiMocks.fetchDashboardNamespaceTruth,
}))

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('refreshNamespaceTruth', () => {
  it('hydrates build identity into serverStatus from project snapshot', async () => {
    apiMocks.fetchDashboardNamespaceTruth.mockResolvedValue({
      generated_at: '2026-03-25T08:16:21Z',
      root: {
        status: {
          project: 'default',
          version: '2.148.0',
          build: {
            release_version: '2.148.0',
            commit: '2897da06',
            started_at: '2026-03-25T08:05:54Z',
            uptime_seconds: 588,
          },
        },
        counts: {
          agents: 0,
          tasks: 1,
          keepers: 3,
        },
      },
    })

    const namespaceTruthStore = await import('./namespace-truth-store')
    const store = await import('./store')

    store.serverStatus.value = null

    await namespaceTruthStore.refreshNamespaceTruth({ force: true })

    const workspaceStatus = namespaceTruthStore.namespaceTruth.value?.root.status as
      | { build?: { commit?: string | null } }
      | undefined
    const mergedBuild = store.serverStatus.value as
      | {
          build?: {
            release_version: string
            commit?: string | null
            started_at: string
            uptime_seconds: number
          }
        }
      | null
    expect(workspaceStatus?.build?.commit).toBe('2897da06')
    expect(mergedBuild?.build).toEqual({
      release_version: '2.148.0',
      commit: '2897da06',
      commit_source: null,
      binary_commit: null,
      binary_commit_source: null,
      repo_head_commit: null,
      repo_head_commit_source: null,
      started_at: '2026-03-25T08:05:54Z',
      uptime_seconds: 588,
    })
  }, 20000)

  it('clears a previous snapshot when the authoritative read fails', async () => {
    apiMocks.fetchDashboardNamespaceTruth.mockRejectedValue(new Error('store unreadable'))
    const namespaceTruthStore = await import('./namespace-truth-store')

    namespaceTruthStore.namespaceTruth.value = {
      generated_at: '2026-08-08T00:00:00Z',
      root: { status: { project: 'default' } },
    } as never

    await namespaceTruthStore.refreshNamespaceTruth({ force: true })

    expect(namespaceTruthStore.namespaceTruth.value).toBeNull()
    expect(namespaceTruthStore.namespaceTruthError.value).toBe('store unreadable')
  })

})
