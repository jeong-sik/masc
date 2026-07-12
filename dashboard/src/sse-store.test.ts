import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost, BoardSortMode, RouteState } from './types'
import {
  DASHBOARD_PUSH_SLICES,
  type DashboardPushSlice,
} from './dashboard-slices'

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

const refreshDashboard = vi.fn<(opts?: { force?: boolean }) => Promise<void>>(async () => {})
const refreshExecution = vi.fn<(opts?: { force?: boolean }) => Promise<void>>(async () => {})
const refreshBoard = vi.fn<() => void>(() => {})
const refreshFusionRuns = vi.fn<() => void>(() => {})
const invalidateDashboardCache = vi.fn<() => void>(() => {})
const hydrateBoardSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydrateShellSnapshot = vi.fn<(payload: unknown, opts?: unknown) => void>(() => {})
const hydrateExecutionSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydratePlanningSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const removeBoardPost = vi.fn<(postId?: string) => void>(() => {})
const refreshForRoute = vi.fn<(nextRoute: CurrentRoute) => void>()
const requestNamespaceTruthNow = vi.fn<() => void>()
const requestNamespaceTruth = vi.fn<() => void>()
const showToast = vi.fn<(message: string, kind?: string, durationMs?: number) => void>()
const replayOasRuntimeTelemetry = vi.fn<() => Promise<void>>(async () => {})
const compositeTick = signal({ name: '', ts_unix: 0 })
const hydrateFleetCompositeSnapshot = vi.fn<(payload: unknown) => void>()
const hydrateGoalTreeSnapshot = vi.fn<(payload: unknown) => boolean>(() => true)
const hydrateGoalLoopSnapshot = vi.fn<(payload: unknown) => boolean>(() => true)
const noteKeeperChatAppended = vi.fn<(name: string, audio?: unknown, blocks?: unknown) => void>()
const refreshActiveKeeperChatHistory = vi.fn<(opts?: { force?: boolean }) => void>()
const reconcileKeeperChatReceipts = vi.fn<(name: string) => Promise<void>>(async () => {})

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
    refreshFusionRuns,
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
    compositeTick,
    hydrateFleetCompositeSnapshot,
  }))
  vi.doMock('./goal-tree-state', () => ({
    hydrateGoalTreeSnapshot,
  }))
  vi.doMock('./goal-loop-state', () => ({
    hydrateGoalLoopSnapshot,
  }))
  vi.doMock('./keeper-runtime', () => ({
    noteKeeperChatAppended,
    reconcileKeeperChatReceipts,
    refreshActiveKeeperChatHistory,
  }))
  vi.doMock('./router', () => ({ route }))
  const sseStore = await import('./sse-store')
  const sse = await import('./sse')
  return { sseStore, sse, compositeTick }
}

describe('setupSSEReaction reconnect hydration', () => {
  const dashboardDeltaTimeoutMs = 10_000

  beforeEach(() => {
    vi.useFakeTimers()
    route.value = { tab: 'overview', params: {}, postId: null }
    refreshDashboard.mockClear()
    refreshDashboard.mockResolvedValue(undefined)
    refreshExecution.mockClear()
    refreshBoard.mockClear()
    refreshFusionRuns.mockClear()
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
    refreshActiveKeeperChatHistory.mockReset()
    reconcileKeeperChatReceipts.mockReset()
    reconcileKeeperChatReceipts.mockResolvedValue(undefined)
    hydrateFleetCompositeSnapshot.mockClear()
    hydrateGoalTreeSnapshot.mockClear()
    hydrateGoalTreeSnapshot.mockReturnValue(true)
    hydrateGoalLoopSnapshot.mockClear()
    hydrateGoalLoopSnapshot.mockReturnValue(true)
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
    compositeTick.value = { name: '', ts_unix: 0 }
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

  it('refreshes the governance approval queue on reconnect (nav-rail badge recovery)', async () => {
    const { sseStore, sse } = await loadSseStore()
    const cleanup = sseStore.setupSSEReaction()
    const refreshGovernance = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGovernanceRefresh(refreshGovernance)

    sse.connected.value = true
    sse.lastDisconnectedAt.value = Date.now() - 1_000
    sse.reconnectCount.value += 1
    await flushAsyncWork()

    // Approvals can arrive/resolve during a disconnect; the always-visible
    // badge must recover them on reconnect, not only on the governance surface.
    expect(refreshGovernance).toHaveBeenCalled()

    vi.clearAllTimers()
    cleanup()
  })

  it('force re-hydrates the open keeper chat on reconnect (replay-buffer gap recovery)', async () => {
    const { sseStore, sse } = await loadSseStore()
    const cleanup = sseStore.setupSSEReaction()

    sse.connected.value = true
    sse.lastDisconnectedAt.value = Date.now() - 1_000
    sse.reconnectCount.value += 1
    await flushAsyncWork()

    // keeper_chat_appended events dropped outside the server replay buffer are
    // unrecoverable through the live stream, so the open panel must re-fetch.
    expect(refreshActiveKeeperChatHistory).toHaveBeenCalledWith({ force: true })

    vi.clearAllTimers()
    cleanup()
  })

  it('surfaces active keeper chat reconnect refresh boundary failures without stopping recovery', async () => {
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    refreshActiveKeeperChatHistory.mockImplementationOnce(() => {
      throw new Error('keeper chat reconnect refresh exploded')
    })
    const { sseStore, sse } = await loadSseStore()
    const cleanup = sseStore.setupSSEReaction()

    sse.connected.value = true
    sse.lastDisconnectedAt.value = Date.now() - 1_000
    sse.reconnectCount.value += 1
    await flushAsyncWork()

    expect(refreshActiveKeeperChatHistory).toHaveBeenCalledWith({ force: true })
    expect(consoleWarn).toHaveBeenCalledWith(
      '[SSE] reconnect keeper chat re-hydration unavailable',
      'keeper chat reconnect refresh exploded',
    )
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })
    expect(requestNamespaceTruthNow).toHaveBeenCalledTimes(1)

    vi.clearAllTimers()
    cleanup()
    consoleWarn.mockRestore()
  })

  it('routes an approval:pending SSE event to the governance refresh (HITL badge contract)', async () => {
    const { sseStore } = await loadSseStore()
    const refreshGovernance = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGovernanceRefresh(refreshGovernance)

    // Pins the FRONTEND routing contract: an `approval:pending` event must
    // reach the governance refresh (and thus the nav-rail/topbar badge). This
    // asserts only the FE literal — the cross-boundary pin that also fails when
    // the backend (keeper_approval_queue.ml) renames the emitted string lives
    // in sse-approval-event-drift.test.ts.
    sseStore.routeServerPushEvent({ type: 'approval:pending' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshGovernance).toHaveBeenCalledWith({ force: true })
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
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })

    cleanup()
  })

  it('normalizes MASC lifecycle aliases before route-scoped execution refresh', async () => {
    const { sseStore, sse } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    const cleanup = sseStore.setupSSEReaction()

    sse.lastEvent.value = {
      type: 'masc/keeper_guardrail',
      name: 'qa-king',
      reason: 'tool boundary',
    }
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })

    cleanup()
  })

  it('forces execution refresh on keeper turn complete for live roster status', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'keepers', params: { keeper: 'qa-king' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'keeper_turn_complete',
      name: 'qa-king',
      turn: 42,
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })
  })

  it('normalizes MASC broadcast aliases before route-scoped execution refresh', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'masc/broadcast',
      from: 'operator',
      content: 'heads up',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
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

  it('routes all board SSE wire variants through the board refresh budget', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }

    for (const type of ['board_post', 'masc/board_comment', 'board_delete'] as const) {
      refreshBoard.mockClear()
      sseStore.routeServerPushEvent({
        type,
        post_id: 'post-1',
      })
      vi.advanceTimersByTime(1_000)
      await flushAsyncWork()
      expect(refreshBoard).toHaveBeenCalledTimes(1)
    }
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

  it('routes fusion_run_status to the registry refresh while on the fusion surface (RFC-0266 Phase 4)', async () => {
    // The live transport is the WS router (this function); the fusion_run_status
    // dispatch case in the legacy sse.ts handleEvent is dead. Without a
    // SIMPLE_ROUTES entry the running -> completed/failed flip never reached
    // refreshFusionRuns and the panel only updated on the ~120s periodic poll.
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'fusion', params: {}, postId: null }

    // routeServerPushEvent dispatches on event.type alone; the run payload is
    // irrelevant to the SIMPLE_ROUTES lookup, so it is omitted here.
    sseStore.routeServerPushEvent({ type: 'fusion_run_status' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshFusionRuns).toHaveBeenCalledTimes(1)
  })

  it('does not refresh fusion runs off the fusion surface (route-scoped budget)', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'overview', params: {}, postId: null }

    // routeServerPushEvent dispatches on event.type alone; the run payload is
    // irrelevant to the SIMPLE_ROUTES lookup, so it is omitted here.
    sseStore.routeServerPushEvent({ type: 'fusion_run_status' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshFusionRuns).not.toHaveBeenCalled()
  })

  it('routes keeper_tool_call to the IDE workspace refresh while on the code surface', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'code', params: {}, postId: null }
    const ideRefresh = vi.fn()
    const unregister = sseStore.registerIdeWorkspaceRefresh(ideRefresh)

    sseStore.routeServerPushEvent({ type: 'keeper_tool_call' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(ideRefresh).toHaveBeenCalledTimes(1)
    unregister()
  })

  it('normalizes the masc/ prefix when routing keeper edits to the IDE refresh', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'code', params: {}, postId: null }
    const ideRefresh = vi.fn()
    sseStore.registerIdeWorkspaceRefresh(ideRefresh)

    sseStore.routeServerPushEvent({ type: 'masc/keeper_tool_call' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(ideRefresh).toHaveBeenCalledTimes(1)
  })

  it('does not refresh the IDE workspace off the code surface (route-scoped)', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'overview', params: {}, postId: null }
    const ideRefresh = vi.fn()
    sseStore.registerIdeWorkspaceRefresh(ideRefresh)

    sseStore.routeServerPushEvent({ type: 'keeper_tool_call' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(ideRefresh).not.toHaveBeenCalled()
  })

  it('stops IDE workspace refreshes once the subscriber unregisters', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'code', params: {}, postId: null }
    const ideRefresh = vi.fn()
    const unregister = sseStore.registerIdeWorkspaceRefresh(ideRefresh)
    unregister()

    sseStore.routeServerPushEvent({ type: 'keeper_tool_call' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(ideRefresh).not.toHaveBeenCalled()
  })

  it('routes keeper_chat_appended pushes to the live chat refresh hook', async () => {
    const { sseStore } = await loadSseStore()

    sseStore.routeServerPushEvent({
      type: 'keeper_chat_appended',
      name: 'echo',
      connector: 'discord',
    })
    await flushAsyncWork()

    expect(noteKeeperChatAppended).toHaveBeenCalledWith('echo', undefined, undefined)
  })

  it('invalidates the authoritative Keeper chat-queue projection once per burst', async () => {
    const { sseStore } = await loadSseStore()
    const refreshQueue = vi.fn()
    sseStore.registerKeeperChatQueueRefresh(refreshQueue)

    sseStore.routeServerPushEvent({
      type: 'keeper_chat_queue_changed',
      keeper_name: 'echo',
      revision: 4,
    })
    sseStore.routeServerPushEvent({
      type: 'keeper_chat_queue_changed',
      keeper_name: 'echo',
      revision: 5,
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshQueue).toHaveBeenCalledTimes(1)
    const expectedRevisions = refreshQueue.mock.calls[0]?.[0] as ReadonlyMap<string, number>
    expect(Array.from(expectedRevisions.entries())).toEqual([['echo', 5]])
    expect(reconcileKeeperChatReceipts).toHaveBeenCalledTimes(1)
    expect(reconcileKeeperChatReceipts).toHaveBeenCalledWith('echo')
  })

  it('forwards RFC-0235 audio clips on keeper_chat_appended to the chat handler', async () => {
    const { sseStore } = await loadSseStore()
    const audio = {
      token: 'clip-1',
      mime: 'audio/mpeg',
      message_text: 'hello',
      duration_sec: 3,
    }

    sseStore.routeServerPushEvent({
      type: 'keeper_chat_appended',
      name: 'echo',
      connector: 'agent',
      audio,
    })
    await flushAsyncWork()

    expect(noteKeeperChatAppended).toHaveBeenCalledWith('echo', audio, undefined)
  })

  it('forwards rich blocks on keeper_chat_appended to the chat handler', async () => {
    const { sseStore } = await loadSseStore()
    const blocks = [{ t: 'p', html: 'hello' }]

    sseStore.routeServerPushEvent({
      type: 'keeper_chat_appended',
      name: 'echo',
      connector: 'dashboard',
      blocks,
    } as any)
    await flushAsyncWork()

    expect(noteKeeperChatAppended).toHaveBeenCalledWith('echo', undefined, blocks)
  })

  it('treats keeper_composite_changed as a signal-only tick and does not hydrate from the event payload', async () => {
    const { sseStore, compositeTick } = await loadSseStore()

    sseStore.routeServerPushEvent({
      type: 'keeper_composite_changed',
      name: 'qa-king',
      ts_unix: 1710000000.123,
      // Any payload-like fields must be ignored; the authoritative read is the
      // per-keeper composite HTTP endpoint.
      payload: { unexpected: true },
    })
    await flushAsyncWork()

    expect(compositeTick.value).toEqual({ name: 'qa-king', ts_unix: 1710000000.123 })
    expect(hydrateFleetCompositeSnapshot).not.toHaveBeenCalled()
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

  it('advances boardOffset when a real server post is prepended', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'workspace', params: { section: 'board' }, postId: null }
    boardExcludeSystem.value = false
    boardOffset.value = 10

    sseStore.routeServerPushEvent({
      type: 'post_created',
      post_id: 'post-1',
      title: 'Note',
      content: 'body',
      author: 'agent-a',
      post_kind: 'direct',
      hearth: 'ops',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(boardPosts.value[0]?.id).toBe('post-1')
    expect(boardOffset.value).toBe(11)
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
      post_kind: 1 as unknown as BoardPost['post_kind'],
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

  it('refreshes observatory telemetry from activity push events on the observatory route', async () => {
    const { sseStore } = await loadSseStore()
    const refreshActivity = vi.fn()
    sseStore.registerActivityRefresh(refreshActivity)
    route.value = { tab: 'monitoring', params: { section: 'observatory' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'activity_graph_changed',
      payload: { kind: 'activity_graph_changed' },
    } as unknown as Parameters<typeof sseStore.routeServerPushEvent>[0])
    vi.advanceTimersByTime(2_000)
    await flushAsyncWork()

    expect(refreshActivity).toHaveBeenCalledTimes(1)
  })

  it('does not trigger observatory telemetry refresh from the workspace board route', async () => {
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
      loop: { schema_version: 1, loop_iteration: '3', overall_status: 'ok' },
    })
    sseStore.hydrateDashboardSlice('composite', {
      generated_at: 1,
      count: 0,
      snapshots: [],
    })

    expect(hydrateBoardSnapshot).toHaveBeenCalledWith({ posts: [], generated_at: 'now' })
    expect(hydratePlanningSnapshot).toHaveBeenCalledWith({ goals: [], generated_at: 'now' })
    expect(hydrateGoalTreeSnapshot).toHaveBeenCalledWith({ tree: [], summary: { total_goals: 0 } })
    // RFC-0284: the goals snapshot's loop sub-field hydrates the goal-loop store.
    expect(hydrateGoalLoopSnapshot).toHaveBeenCalledWith({
      schema_version: 1,
      loop_iteration: '3',
      overall_status: 'ok',
    })
    expect(hydrateFleetCompositeSnapshot).toHaveBeenCalledWith({
      generated_at: 1,
      count: 0,
      snapshots: [],
    })
  })

  it('routes the goal_loop_status delta to the goal-loop store, not as a goals snapshot', async () => {
    const { sseStore } = await loadSseStore()

    // RFC-0284: live goal-loop delta bridged onto the "goals" slice carries the
    // status directly + the goal_loop_status event type. It must hydrate the
    // goal-loop store and must NOT be unpacked as a {planning,tree} snapshot.
    const status = { schema_version: 1, loop_iteration: '8', overall_status: 'warning' }
    sseStore.hydrateDashboardSlice('goals', status, 'goal_loop_status')

    expect(hydrateGoalLoopSnapshot).toHaveBeenCalledWith(status)
    expect(hydratePlanningSnapshot).not.toHaveBeenCalled()
    expect(hydrateGoalTreeSnapshot).not.toHaveBeenCalled()
  })

  it('handles every dashboard push slice advertised to route subscriptions', async () => {
    const { sseStore } = await loadSseStore()
    const payloads: Record<DashboardPushSlice, unknown> = {
      shell: { counts: { agents: 1, tasks: 2, keepers: 3 } },
      namespace: { root: { status: { project: 'default' } } },
      transport: { transports: [] },
      execution: { agents: [], tasks: [], messages: [], keepers: [] },
      goals: {
        planning: { goals: [], generated_at: 'now' },
        tree: { tree: [], summary: { total_goals: 0 } },
      },
      board: { posts: [], generated_at: 'now' },
      composite: { generated_at: 1, count: 0, snapshots: [] },
      operator: { snapshot: { keepers: [] }, digest: { target_type: 'namespace' } },
    }

    for (const slice of DASHBOARD_PUSH_SLICES) {
      expect(() => sseStore.hydrateDashboardSlice(slice, payloads[slice])).not.toThrow()
    }

    expect(hydrateShellSnapshot).toHaveBeenCalledWith(
      payloads.shell,
      { light: true, preserveAuth: true },
    )
    expect(hydrateExecutionSnapshot).toHaveBeenCalledWith(payloads.execution)
    expect(hydrateBoardSnapshot).toHaveBeenCalledWith(payloads.board)
    expect(hydrateFleetCompositeSnapshot).toHaveBeenCalledWith(payloads.composite)
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
  }, dashboardDeltaTimeoutMs)
})
