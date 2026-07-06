import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardFusionRunsResponse } from './api/dashboard-fusion'

const fusionApiMocks = vi.hoisted(() => ({
  fetchFusionRuns: vi.fn<() => Promise<DashboardFusionRunsResponse>>(),
}))

vi.mock('./api/dashboard-fusion', async importOriginal => {
  const actual = await importOriginal<typeof import('./api/dashboard-fusion')>()
  return {
    ...actual,
    fetchFusionRuns: fusionApiMocks.fetchFusionRuns,
  }
})

vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardBootstrap: vi.fn(),
  fetchDashboardShell: vi.fn(),
}))

vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))

vi.mock('./components/common/toast', () => ({
  showToast: vi.fn(),
}))

import {
  fusionRuns,
  fusionRunsError,
  fusionRunsLoading,
  refreshFusionRuns,
} from './store'

beforeEach(() => {
  fusionRuns.value = []
  fusionRunsError.value = null
  fusionRunsLoading.value = false
  vi.clearAllMocks()
})

afterEach(() => {
  fusionRuns.value = []
  fusionRunsError.value = null
  fusionRunsLoading.value = false
})

describe('refreshFusionRuns', () => {
  it('hydrates fusion run registry rows and clears a prior error', async () => {
    fusionRunsError.value = 'previous registry error'
    fusionApiMocks.fetchFusionRuns.mockResolvedValue({
      generatedAt: '2026-07-06T04:10:00Z',
      count: 1,
      runs: [
        {
          runId: 'fus-ok',
          keeper: 'analyst',
          preset: 'trio',
          startedAt: 1_783_106_656,
          status: 'running',
        },
      ],
    })

    await refreshFusionRuns()

    expect(fusionRunsError.value).toBeNull()
    expect(fusionRuns.value).toHaveLength(1)
    expect(fusionRuns.value[0]?.runId).toBe('fus-ok')
    expect(fusionRunsLoading.value).toBe(false)
  })

  it('surfaces registry refresh failure without dropping cached rows', async () => {
    fusionRuns.value = [
      {
        runId: 'fus-cached',
        keeper: 'analyst',
        preset: 'trio',
        startedAt: 1_783_106_656,
        status: 'failed',
        error: 'fusion aborted: 0 of 3 panels answered',
        failureCode: 'panels_unavailable',
      },
    ]
    fusionApiMocks.fetchFusionRuns.mockRejectedValue(new Error('HTTP 503 registry unavailable'))

    await refreshFusionRuns()

    expect(fusionRunsError.value).toBe('HTTP 503 registry unavailable')
    expect(fusionRuns.value).toHaveLength(1)
    expect(fusionRuns.value[0]?.runId).toBe('fus-cached')
    expect(fusionRunsLoading.value).toBe(false)
  })
})
