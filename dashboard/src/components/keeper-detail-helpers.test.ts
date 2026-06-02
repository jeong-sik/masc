import { describe, expect, it, vi } from 'vitest'

const { refreshDashboard, invalidateDashboardCache } = vi.hoisted(() => ({
  refreshDashboard: vi.fn<() => Promise<void>>(),
  invalidateDashboardCache: vi.fn(),
}))

vi.mock('../api', () => ({
  currentDashboardActor: vi.fn(() => 'dashboard'),
  runOperatorAction: vi.fn(),
}))

vi.mock('../store', () => ({
  invalidateDashboardCache,
  refreshDashboard,
}))

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

describe('refreshAfterRuntimeAction', () => {
  it('schedules dashboard refresh without blocking lifecycle buttons', async () => {
    let releaseRefresh: () => void = () => {}
    refreshDashboard.mockReturnValueOnce(new Promise<void>(resolve => {
      releaseRefresh = resolve
    }))

    const { refreshAfterRuntimeAction } = await import('./keeper-detail-helpers')
    await expect(refreshAfterRuntimeAction()).resolves.toBeUndefined()

    expect(invalidateDashboardCache).toHaveBeenCalled()
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })

    releaseRefresh()
  })
})
