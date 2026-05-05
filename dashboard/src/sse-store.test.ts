import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost, BoardSortMode, RouteState } from './types'

void vi

const route: { value: RouteState } = {
  value: { tab: 'overview', params: {}, postId: null },
}
type CurrentRoute = typeof route.value

const keeperHeartbeats = signal(new Map<string, number>())
const serverStatus = signal<unknown>(null)
const boardPosts = signal<BoardPost[]>([])
const boardSortMode = signal<BoardSortMode>('recent')
const boardExcludeSystem = signal(true)
const boardExcludeAutomation = signal(false)
const boardAuthorFilter = signal('')
const boardHearthFilter = signal('')
const boardOffset = signal(0)
const namespaceTruth = signal<unknown>(null)
const namespaceTruthError = signal<unknown>(null)

const refreshDashboard = vi.fn<() => Promise<void>>(async () => {})
const refreshExecution = vi.fn<() => Promise<void>>(async () => {})
const refreshBoard = vi.fn<() => void>(() => {})
const invalidateDashboardCache = vi.fn<() => void>(() => {})
const hydrateBoardSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydrateShellSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydrateExecutionSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydratePlanningSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const removeBoardPost = vi.fn<(postId?: string) => void>(() => {})
const refreshForRoute = vi.fn<(nextRoute: CurrentRoute) => void>()
const requestNamespaceTruthNow = vi.fn<() => void>()
const requestNamespaceTruth = vi.fn<() => void>()
const showToast = vi.fn<(message: string, kind?: string, durationMs?: number) => void>()
const replayOasRuntimeTelemetry = vi.fn<() => Promise<void>>(async () => {})
const hydrateFleetCompositeSnapshot = vi.fn<(payload: unknown) => void>()
const hydrateGoalTreeSnapshot = vi.fn<(payload: unknown) => boolean>(() => true)

async function flushAsyncWork(): Promise<void> {
  await vi.dynamicImportSettled()
  for (let i = 0; i < 6; i += 1) {
    await Promise.resolve()
  }
}

async function loadSseStore() {
  vi.resetModules()
  vi.doMock('./store', () => ({
    keeperHeartbeats,
    invalidateDashboardCache,
    hydrateBoardSnapshot,
    hydrateShellSnapshot,
    hydrateExecutionSnapshot,
    hydratePlanningSnapshot,
    refreshDashboard,
    refreshExecution,
    refreshBoard,
    serverStatus,
    boardPosts,
    boardSortMode,
    boardExcludeSystem,
    boardExcludeAutomation,
    boardAuthorFilter,
    boardHearthFilter,
    boardOffset,
    removeBoardPost,
  }))
  vi.doMock('./namespace-truth-store', () => ({
    requestNamespaceTruthNow,
    requestNamespaceTruth,
    namespaceTruth,
    namespaceTruthError,
    normalizeNamespaceTruth: vi.fn((value: unknown) => value),
  }))
  vi.doMock('./tab-refresh', () => ({ refreshForRoute }))
  vi.doMock('./components/common/toast', () => ({ showToast }))
  vi.doMock('./oas-runtime-store', () => ({
    replayOasRuntimeTelemetry,
    applyOasRuntimeEvent: vi.fn(),
  }))
  vi.doMock('./composite-signals', () => ({
    compositeTick: signal({ name: '', ts_unix: 0 }),
    hydrateFleetCompositeSnapshot,
  }))
  vi.doMock('./goal-tree-state', () => ({
    hydrateGoalTreeSnapshot,
  }))
  vi.doMock('./router', () => ({ route }))
  const sseStore = await import('./sse-store')
  const sse = await import('./sse')
  return { sseStore, sse }
}

describe('setupSSEReaction reconnect hydration', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    route.value = { tab: 'overview', params: {}, postId: null }
    refreshDashboard.mockClear()
    refreshDashboard.mockResolvedValue(undefined)
    refreshExecution.mockClear()
    refreshBoard.mockClear()
    invalidateDashboardCache.mockClear()
    hydrateBoardSnapshot.mockClear()
    hydrateShellSnapshot.mockClear()
    hydrateExecutionSnapshot.mockClear()
    hydratePlanningSnapshot.mockClear()
    removeBoardPost.mockClear()
    refreshForRoute.mockClear()
    requestNamespaceTruthNow.mockClear()
    requestNamespaceTruth.mockClear()
    showToast.mockClear()
    replayOasRuntimeTelemetry.mockClear()
    replayOasRuntimeTelemetry.mockResolvedValue(undefined)
    hydrateFleetCompositeSnapshot.mockClear()
    hydrateGoalTreeSnapshot.mockClear()
    hydrateGoalTreeSnapshot.mockReturnValue(true)
    namespaceTruth.value = null
    namespaceTruthError.value = null
    boardPosts.value = []
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = true
    boardExcludeAutomation.value = false
    boardAuthorFilter.value = ''
    boardHearthFilter.value = ''
    boardOffset.value = 0
    keeperHeartbeats.value = new Map()
    serverStatus.value = null
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.resetModules()
    vi.doUnmock('./store')
    vi.doUnmock('./namespace-truth-store')
    vi.doUnmock('./tab-refresh')
    vi.doUnmock('./components/common/toast')
    vi.doUnmock('./oas-runtime-store')
    vi.doUnmock('./composite-signals')
    vi.doUnmock('./goal-tree-state')
    vi.doUnmock('./router')
  })

  it('forces a dashboard refresh on reconnect before the route-budgeted refresh runs', async () => {
    const { sseStore, sse } = await loadSseStore()
    const cleanup = sseStore.setupSSEReaction()

    sse.connected.value = true
    sse.lastDisconnectedAt.value = Date.now() - 1_000
    sse.reconnectCount.value += 1
    await flushAsyncWork()

    expect(showToast).toHaveBeenCalled()
    expect(replayOasRuntimeTelemetry).toHaveBeenCalledTimes(1)
    expect(requestNamespaceTruthNow).toHaveBeenCalledTimes(1)
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })

    vi.clearAllTimers()
    cleanup()
  })

  it('hydrates the canonical project_snapshot SSE event without an HTTP fetch', async () => {
    const { sseStore, sse } = await loadSseStore()
    const cleanup = sseStore.setupSSEReaction()

    sse.lastEvent.value = {
      type: 'project_snapshot',
      payload: {
        root: {
          status: {
            project: 'default',
          },
        },
      },
    }
    await flushAsyncWork()

    expect(namespaceTruth.value).toEqual({
      root: {
        status: {
          project: 'default',
        },
      },
    })
    expect(requestNamespaceTruthNow).not.toHaveBeenCalled()

    cleanup()
  })

  it('does not refresh hidden heavy surfaces for keeper lifecycle events on overview', async () => {
    const { sseStore, sse } = await loadSseStore()
    const refreshOperator = vi.fn()
    sseStore.registerOperatorRefresh(refreshOperator)
    route.value = { tab: 'overview', params: {}, postId: null }
    const cleanup = sseStore.setupSSEReaction()

    sse.lastEvent.value = {
      type: 'keeper_phase_changed',
      name: 'qa-king',
      prev_phase: 'running',
      new_phase: 'failing',
    }
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).not.toHaveBeenCalled()
    expect(refreshOperator).not.toHaveBeenCalled()

    cleanup()
  })

  it('routes execution SSE refreshes only when the current route needs execution data', async () => {
    const { sseStore, sse } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    const cleanup = sseStore.setupSSEReaction()

    sse.lastEvent.value = {
      type: 'keeper_phase_changed',
      name: 'qa-king',
      prev_phase: 'running',
      new_phase: 'failing',
    }
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith()

    cleanup()
  })

  it('keeps operator lifecycle refreshes scoped to the command route', async () => {
    const { sseStore, sse } = await loadSseStore()
    const refreshOperator = vi.fn()
    sseStore.registerOperatorRefresh(refreshOperator)
    route.value = { tab: 'command', params: {}, postId: null }
    const cleanup = sseStore.setupSSEReaction()

    sse.lastEvent.value = {
      type: 'keeper_turn_complete',
      name: 'qa-king',
      turn: 42,
    }
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshOperator).toHaveBeenCalledTimes(1)
    expect(refreshExecution).not.toHaveBeenCalled()

    cleanup()
  })

  it('routes websocket raw push events through the same route-scoped refresh budget', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'comment_added',
      post_id: 'post-1',
      comment_id: 'comment-1',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).toHaveBeenCalledTimes(1)
  })

  it('routes board reaction changes through the board refresh budget', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'reaction_changed',
      target_type: 'comment',
      target_id: 'comment-1',
      user_id: 'dashboard-reviewer',
      emoji: '🚀',
      reacted: true,
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).toHaveBeenCalledTimes(1)
  })

  it('keeps optimistic post_created hydration inside the active hearth filter', async () => {
    const { sseStore } = await loadSseStore()
    const refreshHearths = vi.fn()
    sseStore.registerBoardHearthsRefresh(refreshHearths)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }
    boardHearthFilter.value = 'ops'

    sseStore.routeServerPushEvent({
      type: 'post_created',
      post_id: 'post-1',
      title: 'Research note',
      content: 'body',
      author: 'agent-a',
      hearth: 'research',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(boardPosts.value).toEqual([])
    expect(refreshBoard).toHaveBeenCalledTimes(1)
    expect(refreshHearths).toHaveBeenCalledTimes(1)
  })

  it('refreshes hearth chips when an optimistic board post carries a hearth', async () => {
    const { sseStore } = await loadSseStore()
    const refreshHearths = vi.fn()
    sseStore.registerBoardHearthsRefresh(refreshHearths)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }
    boardHearthFilter.value = 'ops'

    sseStore.routeServerPushEvent({
      type: 'post_created',
      post_id: 'post-1',
      title: 'Ops note',
      content: 'body',
      author: 'agent-a',
      post_kind: 'automation',
      hearth: 'ops',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(boardPosts.value[0]?.id).toBe('post-1')
    expect(boardPosts.value[0]?.hearth).toBe('ops')
    expect(boardPosts.value[0]?.post_kind).toBe('automation')
    expect(refreshBoard).not.toHaveBeenCalled()
    expect(refreshHearths).toHaveBeenCalledTimes(1)
  })

  it('falls back to board refresh when post_kind is missing under kind exclusions', async () => {
    const { sseStore } = await loadSseStore()
    const refreshHearths = vi.fn()
    sseStore.registerBoardHearthsRefresh(refreshHearths)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }
    boardExcludeAutomation.value = true

    sseStore.routeServerPushEvent({
      type: 'post_created',
      post_id: 'post-1',
      title: 'Unknown kind note',
      content: 'body',
      author: 'agent-a',
      hearth: 'ops',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(boardPosts.value).toEqual([])
    expect(refreshBoard).toHaveBeenCalledTimes(1)
    expect(refreshHearths).toHaveBeenCalledTimes(1)
  })

  it('normalizes malformed post_kind to direct when hydrating optimistic board posts', async () => {
    const { sseStore } = await loadSseStore()
    const refreshHearths = vi.fn()
    sseStore.registerBoardHearthsRefresh(refreshHearths)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }
    boardExcludeSystem.value = false
    boardExcludeAutomation.value = false

    sseStore.routeServerPushEvent({
      type: 'post_created',
      post_id: 'post-1',
      title: 'Malformed kind note',
      content: 'body',
      author: 'agent-a',
      post_kind: 1 as unknown as string,
      hearth: 'ops',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(boardPosts.value[0]?.id).toBe('post-1')
    expect(boardPosts.value[0]?.post_kind).toBe('direct')
    expect(refreshBoard).not.toHaveBeenCalled()
    expect(refreshHearths).toHaveBeenCalledTimes(1)
  })

  it('does not refresh hearth chips for comment-only board events', async () => {
    const { sseStore } = await loadSseStore()
    const refreshHearths = vi.fn()
    sseStore.registerBoardHearthsRefresh(refreshHearths)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'comment_added',
      post_id: 'post-1',
      comment_id: 'comment-1',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).toHaveBeenCalledTimes(1)
    expect(refreshHearths).not.toHaveBeenCalled()
  })

  it('keeps websocket raw push refreshes hidden when the route does not need that surface', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'overview', params: {}, postId: null }

    sseStore.routeServerPushEvent({
      type: 'comment_added',
      post_id: 'post-1',
      comment_id: 'comment-1',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).not.toHaveBeenCalled()
  })

  it('does not trigger observatory graph refresh from the workspace board route', async () => {
    const { sseStore } = await loadSseStore()
    const refreshActivity = vi.fn()
    sseStore.registerActivityRefresh(refreshActivity)
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'activity_graph_changed',
      payload: { kind: 'activity_graph_changed' },
    } as unknown as Parameters<typeof sseStore.routeServerPushEvent>[0])
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshActivity).not.toHaveBeenCalled()
  })

  it('cancels pending stale refresh dispatches after a route switch', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'comment_added',
      post_id: 'post-1',
      comment_id: 'comment-1',
    })
    route.value = { tab: 'monitoring', params: { section: 'observatory' }, postId: null }
    sseStore.cancelPendingSSERefreshes()
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).not.toHaveBeenCalled()
  })

  it('hydrates websocket dashboard snapshots for board, goals, and composite slices', async () => {
    const { sseStore } = await loadSseStore()

    sseStore.hydrateDashboardSlice('board', { posts: [], generated_at: 'now' })
    sseStore.hydrateDashboardSlice('goals', {
      planning: { goals: [], generated_at: 'now' },
      tree: { tree: [], summary: { total_goals: 0 } },
    })
    sseStore.hydrateDashboardSlice('composite', {
      generated_at: 1,
      count: 0,
      snapshots: [],
    })

    expect(hydrateBoardSnapshot).toHaveBeenCalledWith({ posts: [], generated_at: 'now' })
    expect(hydratePlanningSnapshot).toHaveBeenCalledWith({ goals: [], generated_at: 'now' })
    expect(hydrateGoalTreeSnapshot).toHaveBeenCalledWith({ tree: [], summary: { total_goals: 0 } })
    expect(hydrateFleetCompositeSnapshot).toHaveBeenCalledWith({
      generated_at: 1,
      count: 0,
      snapshots: [],
    })
  })

  it('routes websocket dashboard delta event types without treating payloads as snapshots', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    sseStore.hydrateDashboardSlice('board', {
      post_id: 'post-1',
      comment_id: 'comment-1',
    }, 'comment_added')
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(hydrateBoardSnapshot).not.toHaveBeenCalled()
    expect(refreshBoard).toHaveBeenCalledTimes(1)
  })
})
