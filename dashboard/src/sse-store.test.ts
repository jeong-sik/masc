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

const refreshDashboard = vi.fn<(opts?: { force?: boolean }) => Promise<void>>(async () => {})
const refreshExecution = vi.fn<(opts?: { force?: boolean }) => Promise<void>>(async () => {})
const refreshBoard = vi.fn<() => void>(() => {})
const refreshFusionRuns = vi.fn<() => void>(() => {})
const invalidateDashboardCache = vi.fn<() => void>(() => {})
const hydrateBoardSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const hydrateShellSnapshot = vi.fn<(payload: unknown, opts?: unknown) => void>(() => {})
const hydrateExecutionSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const invalidateExecutionSnapshotGeneration = vi.fn<(epoch: string, generation: number) => boolean>(() => true)
const resetExecutionSnapshotGeneration = vi.fn<() => void>(() => {})
const hydratePlanningSnapshot = vi.fn<(payload: unknown) => void>(() => {})
const removeBoardPost = vi.fn<(postId?: string) => void>(() => {})
const refreshForRoute = vi.fn<(nextRoute: CurrentRoute) => void>()
const requestNamespaceTruthNow = vi.fn<() => void>()
const requestNamespaceTruth = vi.fn<() => void>()
const showToast = vi.fn<(message: string, kind?: string, durationMs?: number) => void>()
const replayAgentCoreRuntimeTelemetry = vi.fn<() => Promise<void>>(async () => {})
const hydrateAgentCoreTelemetrySample = vi.fn<(event: unknown) => void>()
const compositeTick = signal({ name: '', ts_unix: 0 })
const hydrateFleetCompositeSnapshot = vi.fn<(payload: unknown) => void>()
const hydrateGoalTreeSnapshot = vi.fn<(payload: unknown) => boolean>(() => true)
const hydrateTransportHealthFromSSE = vi.fn<(payload: unknown) => void>()
const noteKeeperChatAppended = vi.fn<(name: string, audio?: unknown, blocks?: unknown) => void>()
const refreshActiveKeeperChatHistory = vi.fn<(opts?: { force?: boolean }) => void>()

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
    invalidateExecutionSnapshotGeneration,
    resetExecutionSnapshotGeneration,
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
  vi.doMock('./agent-core-runtime-store', () => ({
    replayAgentCoreRuntimeTelemetry,
    applyAgentCoreRuntimeEvent: vi.fn(),
  }))
  vi.doMock('./agent-core-telemetry-store', () => ({
    hydrateAgentCoreTelemetrySample,
  }))
  vi.doMock('./composite-signals', () => ({
    compositeTick,
    hydrateFleetCompositeSnapshot,
  }))
  vi.doMock('./goal-tree-state', () => ({
    hydrateGoalTreeSnapshot,
  }))
  vi.doMock('./components/transport-health', () => ({
    hydrateTransportHealthFromSSE,
  }))
  vi.doMock('./keeper-runtime', () => ({
    noteKeeperChatAppended,
    refreshActiveKeeperChatHistory,
  }))
  vi.doMock('./router', () => ({ route }))
  const sseStore = await import('./sse-store')
  const operatorSignals = await import('./operator-signals')
  const wsState = await import('./dashboard-ws-state')
  return { sseStore, wsState, compositeTick, operatorSignals }
}

describe('setupServerPushReaction reconnect hydration', () => {
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
    invalidateExecutionSnapshotGeneration.mockClear()
    resetExecutionSnapshotGeneration.mockClear()
    hydratePlanningSnapshot.mockClear()
    removeBoardPost.mockClear()
    refreshForRoute.mockClear()
    requestNamespaceTruthNow.mockClear()
    requestNamespaceTruth.mockClear()
    showToast.mockClear()
    replayAgentCoreRuntimeTelemetry.mockClear()
    replayAgentCoreRuntimeTelemetry.mockResolvedValue(undefined)
    hydrateAgentCoreTelemetrySample.mockClear()
    refreshActiveKeeperChatHistory.mockReset()
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
    compositeTick.value = { name: '', ts_unix: 0 }
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.resetModules()
    vi.doUnmock('./store')
    vi.doUnmock('./namespace-truth-store')
    vi.doUnmock('./tab-refresh')
    vi.doUnmock('./components/common/toast')
    vi.doUnmock('./agent-core-runtime-store')
    vi.doUnmock('./agent-core-telemetry-store')
    vi.doUnmock('./composite-signals')
    vi.doUnmock('./goal-tree-state')
    vi.doUnmock('./router')
  })

  it('forces a dashboard refresh on reconnect before the route-budgeted refresh runs', async () => {
    const { sseStore, wsState } = await loadSseStore()
    const cleanup = sseStore.setupServerPushReaction()

    wsState.dashboardWsReady.value = true
    wsState.dashboardWsLastDisconnectedAt.value = Date.now() - 1_000
    wsState.dashboardWsReconnectCount.value += 1
    await flushAsyncWork()

    expect(showToast).toHaveBeenCalled()
    expect(replayAgentCoreRuntimeTelemetry).toHaveBeenCalledTimes(1)
    expect(requestNamespaceTruthNow).toHaveBeenCalledTimes(1)
    expect(resetExecutionSnapshotGeneration).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })

    vi.clearAllTimers()
    cleanup()
  }, 15_000)

  it('refreshes the Gate approval queue on reconnect (nav-rail badge recovery)', async () => {
    const { sseStore, wsState } = await loadSseStore()
    const cleanup = sseStore.setupServerPushReaction()
    const refreshGate = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGateRefresh(refreshGate)

    wsState.dashboardWsReady.value = true
    wsState.dashboardWsLastDisconnectedAt.value = Date.now() - 1_000
    wsState.dashboardWsReconnectCount.value += 1
    await flushAsyncWork()

    // Approvals can arrive/resolve during a disconnect; the always-visible
    // badge must recover them on reconnect, not only on the Gate surface.
    expect(refreshGate).toHaveBeenCalled()

    vi.clearAllTimers()
    cleanup()
  })

  it('force re-hydrates the open keeper chat on reconnect (replay-buffer gap recovery)', async () => {
    const { sseStore, wsState } = await loadSseStore()
    const cleanup = sseStore.setupServerPushReaction()

    wsState.dashboardWsReady.value = true
    wsState.dashboardWsLastDisconnectedAt.value = Date.now() - 1_000
    wsState.dashboardWsReconnectCount.value += 1
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
    const { sseStore, wsState } = await loadSseStore()
    const cleanup = sseStore.setupServerPushReaction()

    wsState.dashboardWsReady.value = true
    wsState.dashboardWsLastDisconnectedAt.value = Date.now() - 1_000
    wsState.dashboardWsReconnectCount.value += 1
    await flushAsyncWork()

    expect(refreshActiveKeeperChatHistory).toHaveBeenCalledWith({ force: true })
    expect(consoleWarn).toHaveBeenCalledWith(
      '[server-push] reconnect keeper chat re-hydration unavailable',
      'keeper chat reconnect refresh exploded',
    )
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })
    expect(requestNamespaceTruthNow).toHaveBeenCalledTimes(1)

    vi.clearAllTimers()
    cleanup()
    consoleWarn.mockRestore()
  })

  it('routes an approval:pending SSE event to the Gate refresh (HITL badge contract)', async () => {
    const { sseStore } = await loadSseStore()
    const refreshGate = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGateRefresh(refreshGate)

    // Pins the FRONTEND routing contract: an `approval:pending` event must
    // reach the Gate refresh (and thus the nav-rail/topbar badge). This
    // asserts only the FE literal — the cross-boundary pin that also fails when
    // the backend (keeper_approval_queue.ml) renames the emitted string lives
    // in sse-approval-event-drift.test.ts.
    sseStore.routeServerPushEvent({ type: 'approval:pending' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshGate).toHaveBeenCalledWith({ force: true })
  })

  it('projects a failed approval audit receipt from SSE without changing the committed event', async () => {
    const { sseStore } = await loadSseStore()
    const observe = vi.fn()
    sseStore.registerGateAuditReceiptObserver(observe)

    sseStore.routeServerPushEvent({
      type: 'approval:resolved',
      payload: {
        id: 'appr-sse-audit',
        audit: {
          event: 'resolved',
          recorded: false,
          stage: 'append',
          detail: 'audit append unavailable',
        },
      },
    })

    expect(observe).toHaveBeenCalledWith(
      [{
        event: 'resolved',
        recorded: false,
        stage: 'append',
        detail: 'audit append unavailable',
      }],
      { id: 'appr-sse-audit', transport: 'sse' },
    )
  })

  it('projects a failed authorization audit receipt without refreshing Gate state', async () => {
    const { sseStore } = await loadSseStore()
    const observe = vi.fn()
    const refreshGate = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGateAuditReceiptObserver(observe)
    sseStore.registerGateRefresh(refreshGate)

    sseStore.routeServerPushEvent({
      type: 'approval:audit',
      payload: {
        id: 'appr-consumed',
        audit: {
          event: 'grant_consumed',
          recorded: false,
          stage: 'append',
          detail: 'audit append unavailable',
        },
      },
    })

    expect(observe).toHaveBeenCalledWith(
      [{
        event: 'grant_consumed',
        recorded: false,
        stage: 'append',
        detail: 'audit append unavailable',
      }],
      { id: 'appr-consumed', transport: 'sse' },
    )
    expect(refreshGate).not.toHaveBeenCalled()
  })

  it('rejects an audit receipt that does not match its SSE envelope', async () => {
    const { sseStore } = await loadSseStore()
    const observe = vi.fn()
    sseStore.registerGateAuditReceiptObserver(observe)

    sseStore.routeServerPushEvent({
      type: 'approval:pending',
      payload: {
        id: 'appr-mismatch',
        audit: { event: 'resolved', recorded: true },
      },
    })

    expect(observe).not.toHaveBeenCalled()
  })

  it('routes an approval:summary_updated SSE event to the Gate refresh (Auto Judge verdict contract)', async () => {
    const { sseStore } = await loadSseStore()
    const refreshGate = vi.fn<(opts?: { force?: boolean }) => void>()
    sseStore.registerGateRefresh(refreshGate)

    // The Auto Judge verdict lands on this event, not on approval:resolved: a
    // `require_human` judgment settles the summary while the row stays pending,
    // so resolution never fires. Without this route the queue kept rendering
    // "generating summary" until the 120-180s periodic sweep even though the
    // judge had settled in ~2s.
    sseStore.routeServerPushEvent({ type: 'approval:summary_updated' })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshGate).toHaveBeenCalledWith({ force: true })
  })

  it('hydrates the canonical project_snapshot SSE event without an HTTP fetch', async () => {
    const { sseStore } = await loadSseStore()

    sseStore.routeServerPushEvent({
      type: 'project_snapshot',
      payload: {
        root: {
          status: {
            project: 'default',
          },
        },
      },
    })
    await flushAsyncWork()

    expect(namespaceTruth.value).toEqual({
      root: {
        status: {
          project: 'default',
        },
      },
    })
    expect(requestNamespaceTruthNow).not.toHaveBeenCalled()

  })

  it('clears operator state when a pushed snapshot violates the envelope contract', async () => {
    const { sseStore, operatorSignals } = await loadSseStore()
    operatorSignals.operatorSnapshot.value = {
      root: {},
      keepers: [],
      inference_inflight: null,
      persistent_agents: [],
      recent_messages: [],
      pending_confirm_envelope: {
        items: [],
        summary: {
          actor_filter: null,
          filter_active: false,
          visible_count: 0,
          total_count: 0,
          hidden_count: 0,
          hidden_actors: [],
          confirm_required_actions: [],
        },
      },
      available_actions: [],
    }

    sseStore.hydrateDashboardSlice('operator', {
      keepers: [],
      snapshot_epoch: 'epoch-invalid-envelope',
      snapshot_generation: 1,
      snapshot_compute_sequence: 1,
      snapshot_terminal_sequence: 1,
    }, 'operator_snapshot')

    expect(operatorSignals.operatorSnapshot.value).toBeNull()
    expect(operatorSignals.operatorError.value).toBe('invalid pending_confirm_envelope')

    sseStore.hydrateDashboardSlice('operator', {
      snapshot_epoch: 'epoch-recovered',
      snapshot_generation: 1,
      snapshot_compute_sequence: 2,
      snapshot_terminal_sequence: 2,
      pending_confirm_envelope: {
        items: [],
        summary: {
          actor_filter: null,
          filter_active: false,
          visible_count: 0,
          total_count: 0,
          hidden_count: 0,
          hidden_actors: [],
          confirm_required_actions: [],
        },
      },
    }, 'operator_snapshot')

    expect(operatorSignals.operatorSnapshot.value).not.toBeNull()
    expect(operatorSignals.operatorError.value).toBeNull()
  })

  it('clears operator state when the pushed snapshot payload is not an object', async () => {
    const { sseStore, operatorSignals } = await loadSseStore()
    operatorSignals.operatorSnapshot.value = {
      root: {},
      keepers: [],
      inference_inflight: null,
      persistent_agents: [],
      recent_messages: [],
      pending_confirm_envelope: {
        items: [],
        summary: {
          actor_filter: null,
          filter_active: false,
          visible_count: 0,
          total_count: 0,
          hidden_count: 0,
          hidden_actors: [],
          confirm_required_actions: [],
        },
      },
      available_actions: [],
    }

    sseStore.hydrateDashboardSlice('operator', null, 'operator_snapshot')

    expect(operatorSignals.operatorSnapshot.value).toBeNull()
    expect(operatorSignals.operatorError.value).toBe('operator snapshot payload is invalid')
  })

  it('does not refresh hidden heavy surfaces for keeper lifecycle events on overview', async () => {
    const { sseStore } = await loadSseStore()
    const refreshOperator = vi.fn()
    sseStore.registerOperatorRefresh(refreshOperator)
    route.value = { tab: 'overview', params: {}, postId: null }
    sseStore.routeServerPushEvent({
      type: 'keeper_phase_changed',
      name: 'qa-king',
      prev_phase: 'running',
      new_phase: 'failing',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).not.toHaveBeenCalled()
    expect(refreshOperator).not.toHaveBeenCalled()

  })

  it('routes execution SSE refreshes only when the current route needs execution data', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    sseStore.routeServerPushEvent({
      type: 'keeper_phase_changed',
      name: 'qa-king',
      prev_phase: 'running',
      new_phase: 'failing',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })

  })

  it('normalizes MASC lifecycle aliases before route-scoped execution refresh', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'agents' }, postId: null }
    sseStore.routeServerPushEvent({
      type: 'masc/keeper_compaction',
      name: 'qa-king',
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshExecution).toHaveBeenCalledTimes(1)
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })

  })

  it('refreshes only the scoped Keeper status on turn complete', async () => {
    const { sseStore } = await loadSseStore()
    const refreshKeeperTurn = vi.fn<(keeperName: string) => void>()
    sseStore.registerKeeperTurnRefresh(refreshKeeperTurn)
    route.value = { tab: 'keepers', params: { keeper: 'qa-king' }, postId: null }

    sseStore.routeServerPushEvent({
      type: 'keeper_turn_complete',
      name: 'qa-king',
      turn: 42,
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    // The agent-core hook precedes durable commit, so rebuilding the global execution
    // snapshot here is both premature and expensive. The registered
    // keeper-scoped status reader remains the authoritative immediate refresh.
    expect(refreshExecution).not.toHaveBeenCalled()
    expect(refreshKeeperTurn).toHaveBeenCalledTimes(1)
    expect(refreshKeeperTurn).toHaveBeenCalledWith('qa-king')
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
    const { sseStore } = await loadSseStore()
    const refreshOperator = vi.fn()
    sseStore.registerOperatorRefresh(refreshOperator)
    route.value = { tab: 'command', params: {}, postId: null }
    sseStore.routeServerPushEvent({
      type: 'keeper_turn_complete',
      name: 'qa-king',
      turn: 42,
    })
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshOperator).toHaveBeenCalledTimes(1)
    expect(refreshExecution).not.toHaveBeenCalled()

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

  it('refreshes the mounted internal-agent registry immediately from websocket invalidation', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'internal-agents' }, postId: null }
    const refresh = vi.fn()
    const unregister = sseStore.registerInternalAgentRefresh(refresh)

    sseStore.routeServerPushEvent({ type: 'internal_agent_runs_changed' })
    vi.advanceTimersByTime(1)
    await flushAsyncWork()

    expect(refresh).toHaveBeenCalledTimes(1)
    unregister()
  })

  it('refreshes Fusion rows inside Internal Agents from the existing Fusion websocket event', async () => {
    const { sseStore } = await loadSseStore()
    route.value = { tab: 'monitoring', params: { section: 'internal-agents' }, postId: null }
    const refresh = vi.fn()
    const unregister = sseStore.registerInternalAgentRefresh(refresh)

    sseStore.routeServerPushEvent({ type: 'fusion_run_status' })
    vi.advanceTimersByTime(1)
    await flushAsyncWork()

    expect(refresh).toHaveBeenCalledTimes(1)
    expect(refreshFusionRuns).not.toHaveBeenCalled()
    unregister()
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

  it('routes IDE cursor invalidations delivered by the dashboard websocket', async () => {
    const { sseStore } = await loadSseStore()
    const cursorRefresh = vi.fn()
    const unregister = sseStore.registerIdeCursorRefresh(cursorRefresh)

    sseStore.routeServerPushEvent({
      type: 'ide_cursor_changed',
      keeper_id: 'kidsnote',
    })
    vi.advanceTimersByTime(1)
    await flushAsyncWork()

    expect(cursorRefresh).toHaveBeenCalledOnce()
    unregister()
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

  it('delivers every Keeper chat-operation inventory invalidation immediately', async () => {
    const { sseStore } = await loadSseStore()
    const refreshQueue = vi.fn()
    sseStore.registerKeeperWaitingInventoryRefresh(refreshQueue)

    sseStore.routeServerPushEvent({
      type: 'keeper_waiting_inventory_changed',
      keeper_name: 'echo',
      queue_kind: 'chat_operation',
    })
    sseStore.routeServerPushEvent({
      type: 'keeper_waiting_inventory_changed',
      keeper_name: 'echo',
      queue_kind: 'chat_operation',
    })
    expect(refreshQueue).toHaveBeenCalledTimes(2)
    expect(refreshQueue).toHaveBeenNthCalledWith(1, 'echo')
    expect(refreshQueue).toHaveBeenNthCalledWith(2, 'echo')
  })

  it('refreshes waiting inventory for event-queue changes', async () => {
    const { sseStore } = await loadSseStore()
    const refreshQueue = vi.fn()
    sseStore.registerKeeperWaitingInventoryRefresh(refreshQueue)

    sseStore.routeServerPushEvent({
      type: 'keeper_waiting_inventory_changed',
      keeper_name: 'echo',
      queue_kind: 'event_queue',
    })
    expect(refreshQueue).toHaveBeenCalledTimes(1)
    expect(refreshQueue).toHaveBeenCalledWith('echo')
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

  it('routes agent_core_telemetry_sample to the telemetry read model without an HTTP refresh', async () => {
    const { sseStore } = await loadSseStore()

    // The push payload carries the sample itself (schemas/sse.ts validates the
    // envelope), so the read model hydrates directly — nothing to re-fetch.
    sseStore.routeServerPushEvent({
      type: 'agent_core_telemetry_sample',
      provider_id: 'runtime',
      model_id: 'runtime',
      payload: {
        sample: { ttfb_ms: 120.5, total_duration_ms: 845.2, status: { kind: 'success' } },
        recorded_at: 1_712_000_000,
      },
      ts_unix: 1_712_000_000,
    })
    await flushAsyncWork()

    expect(hydrateAgentCoreTelemetrySample).toHaveBeenCalledTimes(1)
    expect(refreshExecution).not.toHaveBeenCalled()
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
    sseStore.cancelPendingServerPushRefreshes()
    vi.advanceTimersByTime(1_000)
    await flushAsyncWork()

    expect(refreshBoard).not.toHaveBeenCalled()
  })

  // Every dashboard delta carries an event_type. This table pins the complete
  // server mapping and the typed hydration arm selected for each event.
  it('routes every server-producible dashboard delta by its event type', async () => {
    const { sseStore } = await loadSseStore()

    const transportPayload = {
      status: 'initializing',
      generated_at: '2026-08-08T12:00:00Z',
      message: 'transport health warming',
      projection_diagnostics: {
        source: 'cached_surface',
        cache_state: 'initializing',
        last_success_at: null,
        last_attempt_at: '2026-08-08T12:00:00Z',
        last_error_at: '2026-08-08T12:00:01Z',
        stale_reason: 'transport metric read failed',
        stale_age_ms: null,
      },
    }

    // The full image of dashboard_slice_for_sse_type
    // (lib/server/server_mcp_transport_ws.ml). If the server gains a mapping,
    // this list has to gain the event type, and the assertion below fails until
    // a handler exists for it.
    const deltas: Array<{ eventType: string; slice: string; payload: unknown }> = [
      { eventType: 'project_snapshot', slice: 'namespace',
        payload: { root: { status: { project: 'default' } } } },
      { eventType: 'namespace_truth_snapshot', slice: 'namespace',
        payload: { root: { status: { project: 'default' } } } },
      { eventType: 'execution_snapshot', slice: 'execution',
        payload: { agents: [], tasks: [], messages: [], keepers: [] } },
      { eventType: 'operator_snapshot', slice: 'operator', payload: {
        keepers: [],
        snapshot_epoch: 'epoch-table',
        snapshot_generation: 1,
        snapshot_compute_sequence: 1,
        snapshot_terminal_sequence: 1,
        pending_confirm_envelope: {
          items: [],
          summary: {
            actor_filter: null,
            filter_active: false,
            visible_count: 0,
            total_count: 0,
            hidden_count: 0,
            hidden_actors: [],
            confirm_required_actions: [],
          },
        },
      } },
      { eventType: 'operator_digest', slice: 'operator', payload: { target_type: 'namespace' } },
      { eventType: 'transport_health_snapshot', slice: 'transport', payload: transportPayload },
      { eventType: 'keeper_composite_changed', slice: 'composite',
        payload: { name: 'alpha', ts_unix: 1 } },
    ]

    for (const { eventType, slice, payload } of deltas) {
      expect(() => sseStore.hydrateDashboardSlice(slice, payload, eventType)).not.toThrow()
    }
    await flushAsyncWork()

    // Not merely "did not throw": the typed arms must actually hydrate.
    expect(hydrateExecutionSnapshot).toHaveBeenCalledWith(
      { agents: [], tasks: [], messages: [], keepers: [] },
    )
    expect(hydrateTransportHealthFromSSE).toHaveBeenCalledWith(transportPayload)
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
