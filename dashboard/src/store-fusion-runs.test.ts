import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardFusionRunsResponse } from './api/dashboard-fusion'
import type { BoardPost } from './types'

const fusionApiMocks = vi.hoisted(() => ({
  fetchDashboardMemory: vi.fn<() => Promise<{ posts: BoardPost[] }>>(),
  fetchFusionRuns: vi.fn<() => Promise<DashboardFusionRunsResponse>>(),
  fetchFusionRunEvidencePost: vi.fn<(runId: string) => Promise<BoardPost | null>>(),
}))

// Spread the real module rather than listing what the store uses: the store
// imports it lazily and a partial mock breaks the next time it reaches for
// something else in there.
vi.mock('./api/board', async importOriginal => {
  const actual = await importOriginal<typeof import('./api/board')>()
  return {
    ...actual,
    fetchFusionRunEvidencePost: fusionApiMocks.fetchFusionRunEvidencePost,
  }
})

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
  fusionRunObservation,
  fusionRunsError,
  fusionRunsLoading,
  loadFusionRunEvidence,
  refreshFusionBoard,
  refreshFusionRuns,
} from './store'

beforeEach(() => {
  fusionBoardPosts.value = []
  fusionBoardError.value = null
  fusionBoardLoading.value = false
  fusionRuns.value = []
  fusionRunObservation.value = null
  fusionRunsError.value = null
  fusionRunsLoading.value = false
  vi.clearAllMocks()
})

afterEach(() => {
  fusionBoardPosts.value = []
  fusionBoardError.value = null
  fusionBoardLoading.value = false
  fusionRuns.value = []
  fusionRunObservation.value = null
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
    votes: 0,
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

// The board window is 500 posts, so a run that has fallen out of it has no
// evidence in the list -- and used to have none anywhere, permanently. These
// pin the way back in: by run id, once per run, and askable again after the
// list is refetched.
describe('loadFusionRunEvidence', () => {
  it('merges a post the 500-row window no longer reaches', async () => {
    fusionBoardPosts.value = [fusionPost('fus-recent')]
    fusionApiMocks.fetchFusionRunEvidencePost.mockResolvedValue(fusionPost('fus-old'))

    await loadFusionRunEvidence('fus-old')

    expect(fusionApiMocks.fetchFusionRunEvidencePost).toHaveBeenCalledWith('fus-old')
    expect(fusionBoardPosts.value.map(post => post.id).sort()).toEqual([
      'fus-old',
      'fus-recent',
    ])
  })

  it('asks once per run id, so a render loop cannot make a request per frame', async () => {
    fusionApiMocks.fetchFusionRunEvidencePost.mockResolvedValue(fusionPost('fus-once'))

    await loadFusionRunEvidence('fus-once')
    await loadFusionRunEvidence('fus-once')

    expect(fusionApiMocks.fetchFusionRunEvidencePost).toHaveBeenCalledTimes(1)
  })

  it('asks again after the list is refetched, because the run may have landed its post', async () => {
    fusionApiMocks.fetchFusionRunEvidencePost.mockResolvedValue(null)
    await loadFusionRunEvidence('fus-pending')
    expect(fusionBoardPosts.value).toHaveLength(0)

    fusionApiMocks.fetchDashboardMemory.mockResolvedValue({ posts: [] })
    await refreshFusionBoard()

    fusionApiMocks.fetchFusionRunEvidencePost.mockResolvedValue(fusionPost('fus-pending'))
    await loadFusionRunEvidence('fus-pending')

    expect(fusionApiMocks.fetchFusionRunEvidencePost).toHaveBeenCalledTimes(2)
    expect(fusionBoardPosts.value.map(post => post.id)).toEqual(['fus-pending'])
  })

  it('keeps the cached list when the fetch fails, so the pane keeps its sparse detail', async () => {
    fusionBoardPosts.value = [fusionPost('fus-kept')]
    fusionApiMocks.fetchFusionRunEvidencePost.mockRejectedValue(new Error('HTTP 404'))

    await loadFusionRunEvidence('fus-missing')

    expect(fusionBoardPosts.value.map(post => post.id)).toEqual(['fus-kept'])
    expect(fusionBoardError.value).toBeNull()
  })
})

describe('refreshFusionRuns', () => {
  it('hydrates fusion run registry rows and clears a prior error', async () => {
    fusionRunsError.value = 'previous registry error'
    fusionApiMocks.fetchFusionRuns.mockResolvedValue({
      replay: { status: 'complete', linesRead: 68, malformedLines: 34, droppedRunning: 0 },
      historicalEvidence: [{ runId: 'old-run', postId: 'old-post', title: 'Preserved', createdAt: 100 }],
      generatedAt: '2026-07-06T04:10:00Z',
      count: 1,
      runs: [
        {
          runId: 'fus-ok',
          keeper: 'analyst',
          preset: 'trio',
          topology: null,
          startedAt: 1_783_106_656,
          status: 'running',
        },
      ],
    })

    await refreshFusionRuns()

    expect(fusionRunsError.value).toBeNull()
    expect(fusionRuns.value).toHaveLength(1)
    expect(fusionRuns.value[0]?.runId).toBe('fus-ok')
    expect(fusionRunObservation.value?.replay).toMatchObject({ malformedLines: 34 })
    expect(fusionRunObservation.value?.historicalEvidence[0]?.postId).toBe('old-post')
    expect(fusionRunsLoading.value).toBe(false)
  })

  it('surfaces registry refresh failure without dropping cached rows', async () => {
    fusionRunObservation.value = { replay: { status: 'absent' }, historicalEvidence: [
      { runId: 'old-run', postId: 'old-post', title: 'Preserved', createdAt: 100 },
    ] }
    fusionRuns.value = [
      {
        runId: 'fus-cached',
        keeper: 'analyst',
        preset: 'trio',
        topology: null,
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
    expect(fusionRunObservation.value?.historicalEvidence[0]?.postId).toBe('old-post')
    expect(fusionRunsLoading.value).toBe(false)
  })
})
