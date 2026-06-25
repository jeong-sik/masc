import { describe, expect, it, vi } from 'vitest'

const { refreshDashboard, invalidateDashboardCache, refreshKeeperRuntimeStatus } = vi.hoisted(() => ({
  refreshDashboard: vi.fn<() => Promise<void>>(),
  invalidateDashboardCache: vi.fn(),
  refreshKeeperRuntimeStatus: vi.fn<() => Promise<void>>(),
}))

vi.mock('../api', () => ({
  currentDashboardActor: vi.fn(() => 'dashboard'),
  runOperatorAction: vi.fn(),
}))

vi.mock('../store', () => ({
  invalidateDashboardCache,
  refreshDashboard,
  refreshKeeperRuntimeStatus,
}))

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

describe('refreshAfterRuntimeAction', () => {
  it('schedules scoped execution + light shell refresh without blocking lifecycle buttons', async () => {
    // Keeper runtime actions reconcile against execution rows plus shell
    // runtime-health, not a full dashboard bootstrap — see refreshAfterRuntimeAction.
    let releaseRefresh: () => void = () => {}
    refreshKeeperRuntimeStatus.mockReturnValueOnce(new Promise<void>(resolve => {
      releaseRefresh = resolve
    }))

    const { refreshAfterRuntimeAction } = await import('./keeper-detail-helpers')
    // Resolves immediately even while the refetch is still in flight: the
    // helper fires-and-forgets so the lifecycle button is never blocked.
    await expect(refreshAfterRuntimeAction()).resolves.toBeUndefined()

    expect(refreshKeeperRuntimeStatus).toHaveBeenCalledWith()
    // The full-bootstrap path is no longer taken for keeper actions.
    expect(refreshDashboard).not.toHaveBeenCalled()

    releaseRefresh()
  })
})
