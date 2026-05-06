import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardMemory: vi.fn(),
}))

const toastMocks = vi.hoisted(() => ({
  showToast: vi.fn(),
}))

vi.mock('./api/dashboard', () => ({
  fetchDashboardMemory: apiMocks.fetchDashboardMemory,
}))

vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardShell: vi.fn(),
}))

vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))

vi.mock('./components/common/toast', () => ({
  showToast: toastMocks.showToast,
}))

import {
  boardHasMore,
  boardLoading,
  boardLoadingMore,
  boardOffset,
  boardPosts,
  boardSortMode,
  loadMoreBoardPosts,
  refreshBoard,
} from './store'
import { boardLatencyMetrics, resetBoardLatencyMetrics } from './board-metrics'

beforeEach(() => {
  resetBoardLatencyMetrics()
  boardPosts.value = []
  boardOffset.value = 0
  boardHasMore.value = true
  boardLoading.value = false
  boardLoadingMore.value = false
  boardSortMode.value = 'recent'
  vi.clearAllMocks()
})

afterEach(() => {
  vi.restoreAllMocks()
  resetBoardLatencyMetrics()
})

describe('board list latency metrics', () => {
  it('records refreshBoard list latency on success', async () => {
    vi.spyOn(performance, 'now')
      .mockReturnValueOnce(0)
      .mockReturnValueOnce(42)
    apiMocks.fetchDashboardMemory.mockResolvedValue({
      posts: [],
      has_more: false,
      total: 0,
      generated_at: '2026-05-06T00:00:00Z',
    })

    await refreshBoard()

    expect(boardLatencyMetrics.value.list).toMatchObject({
      last_latency_ms: 42,
      last_ok: true,
      sample_count: 1,
      failure_count: 0,
      last_error: null,
    })
  })

  it('records load-more failures without throwing through the UI path', async () => {
    vi.spyOn(performance, 'now')
      .mockReturnValueOnce(10)
      .mockReturnValueOnce(35)
    boardHasMore.value = true
    apiMocks.fetchDashboardMemory.mockRejectedValue(new Error('page timeout'))

    await loadMoreBoardPosts()

    expect(boardLatencyMetrics.value.list_more).toMatchObject({
      last_latency_ms: 25,
      last_ok: false,
      sample_count: 1,
      failure_count: 1,
      last_error: 'page timeout',
    })
    expect(toastMocks.showToast).toHaveBeenCalledWith('다음 페이지를 불러오지 못했습니다', 'error')
  })
})
