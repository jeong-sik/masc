import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardFusionRunsResponse } from './api/dashboard-fusion'
import type { BoardPost } from './types'

const fusionApiMocks = vi.hoisted(() => ({
  fetchDashboardMemory: vi.fn<() => Promise<{ posts: BoardPost[] }>>(),
  fetchFusionRuns: vi.fn<() => Promise<DashboardFusionRunsResponse>>(),
}))

vi.mock('./api/dashboard-fusion', async importOriginal => {
  const actual = await importOriginal<typeof import('./api/dashboard-fusion')>()
  return {
    ...actual,
    fetchFusionRuns: fusionApiMocks.fetchFusionRuns,
  }
})

vi.mock('./api/dashboard-execution', () => ({
  fetchDashboardMemory: fusionApiMocks.fetchDashboardMemory,
}))

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
  fusionBoardError,
  fusionBoardLoading,
  fusionBoardPosts,
  fusionRuns,
  fusionRunsError,
  fusionRunsLoading,
  refreshFusionBoard,
  refreshFusionRuns,
} from './store'

beforeEach(() => {
  fusionBoardPosts.value = []
  fusionBoardError.value = null
  fusionBoardLoading.value = false
  fusionRuns.value = []
  fusionRunsError.value = null
  fusionRunsLoading.value = false
  vi.clearAllMocks()
})

afterEach(() => {
  fusionBoardPosts.value = []
  fusionBoardError.value = null
  fusionBoardLoading.value = false
  fusionRuns.value = []
  fusionRunsError.value = null
  fusionRunsLoading.value = false
})

function fusionPost(id: string): BoardPost {
  return {
    id,
    author: 'fusion-keeper',
    post_kind: 'automation',
    pinned: false,
    title: `Fusion ${id}`,
    body: '',
    content: '',
    meta: { source: 'fusion', run_id: id },
    tags: [],
    votes: null,
    comment_count: 0,
    created_at: '2026-07-06T04:00:00Z',
    updated_at: '2026-07-06T04:00:00Z',
  } as BoardPost
}

describe('refreshFusionBoard', () => {
  it('hydrates board-sink rows and clears a prior error', async () => {
    fusionBoardError.value = 'previous board error'
    fusionApiMocks.fetchDashboardMemory.mockResolvedValue({
      posts: [fusionPost('fus-board-ok')],
    })

    await refreshFusionBoard()

    expect(fusionBoardError.value).toBeNull()
    expect(fusionBoardPosts.value).toHaveLength(1)
    expect(fusionBoardPosts.value[0]?.id).toBe('fus-board-ok')
    expect(fusionApiMocks.fetchDashboardMemory).toHaveBeenCalledWith('recent', {
      limit: 500,
      offset: 0,
    })
    expect(fusionBoardLoading.value).toBe(false)
  })

  it('surfaces board-sink refresh failure without dropping cached posts', async () => {
    fusionBoardPosts.value = [fusionPost('fus-board-cached')]
    fusionApiMocks.fetchDashboardMemory.mockRejectedValue(new Error('HTTP 502 board sink unavailable'))

    await refreshFusionBoard()

    expect(fusionBoardError.value).toBe('HTTP 502 board sink unavailable')
    expect(fusionBoardPosts.value).toHaveLength(1)
    expect(fusionBoardPosts.value[0]?.id).toBe('fus-board-cached')
    expect(fusionBoardLoading.value).toBe(false)
  })
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
