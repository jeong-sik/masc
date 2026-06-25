import { describe, expect, it, vi } from 'vitest'

const { refreshDashboard, invalidateDashboardCache, refreshExecution } = vi.hoisted(() => ({
  refreshDashboard: vi.fn<() => Promise<void>>(),
  invalidateDashboardCache: vi.fn(),
  refreshExecution: vi.fn<() => Promise<void>>(),
}))

vi.mock('../api', () => ({
  currentDashboardActor: vi.fn(() => 'dashboard'),
  runOperatorAction: vi.fn(),
}))

vi.mock('../store', () => ({
  invalidateDashboardCache,
  refreshDashboard,
  refreshExecution,
}))

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

describe('refreshAfterRuntimeAction', () => {
  it('schedules a scoped execution refresh without blocking lifecycle buttons', async () => {
    // Keeper runtime actions reconcile against the execution slice (the
    // roster), not a full dashboard bootstrap — see refreshAfterRuntimeAction.
    let releaseRefresh: () => void = () => {}
    refreshExecution.mockReturnValueOnce(new Promise<void>(resolve => {
      releaseRefresh = resolve
    }))

    const { refreshAfterRuntimeAction } = await import('./keeper-detail-helpers')
    // Resolves immediately even while the refetch is still in flight: the
    // helper fires-and-forgets so the lifecycle button is never blocked.
    await expect(refreshAfterRuntimeAction()).resolves.toBeUndefined()

    expect(refreshExecution).toHaveBeenCalledWith({ force: true })
    // The full-bootstrap path is no longer taken for keeper actions.
    expect(refreshDashboard).not.toHaveBeenCalled()

    releaseRefresh()
  })
})
