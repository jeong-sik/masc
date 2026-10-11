import { operationDeliveryProvenance, toolCallDeliveryProvenance } from './keeper-delivery-provenance'
import { initialKeeperResponseState } from './lib/keeper-response-state'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type * as ApiCore from './api/core'

const { callMcpTool } = vi.hoisted(() => ({ callMcpTool: vi.fn() }))
const { runOperatorAction } = vi.hoisted(() => ({ runOperatorAction: vi.fn() }))
const { invalidateDashboardCache, refreshDashboard, shellAuthSummary } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
  shellAuthSummary: { value: { effective_role: 'admin' } },
}))
const {
  cancelKeeperChatOperation,
  fetchKeeperChatOperation,
  fetchKeeperChatHistory,
  streamKeeperMessage,
} = vi.hoisted(() => ({
  cancelKeeperChatOperation: vi.fn(),
  fetchKeeperChatOperation: vi.fn(),
  fetchKeeperChatHistory: vi.fn(),
  streamKeeperMessage: vi.fn(),
}))
const { fetchKeeperToolCalls } = vi.hoisted(() => ({
  fetchKeeperToolCalls: vi.fn(async (): Promise<{ entries: ToolCallEntry[] }> => ({ entries: [] })),
}))

vi.mock('./api/mcp', () => ({ callMcpTool }))
vi.mock('./api/core', async importOriginal => ({
  ...await importOriginal<typeof ApiCore>(),
  runOperatorAction,
}))
vi.mock('./api/keeper', () => ({
  cancelKeeperChatOperation,
  fetchKeeperChatOperation,
  fetchKeeperChatHistory,
  streamKeeperMessage,
}))
vi.mock('./api/dashboard', () => ({ fetchKeeperToolCalls }))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard, shellAuthSummary }))
vi.mock('./api/keeper-turn-events', () => ({
  fetchKeeperCurrentTurn: vi.fn().mockResolvedValue({ state: 'idle' }),
  fetchKeeperTurnEvents: vi.fn(),
}))
import { fetchKeeperTurnEvents } from './api/keeper-turn-events'
import { _resetKeeperAutonomousRecoveryForTests } from './keeper-autonomous-stream'

import {
  _resetActiveKeeperStreamsForTests,
  _resetLiveSendRequestOwnersForTests,
  activeKeeperName,
  keeperActionErrors,
  keeperChatHistoryErrors,
  keeperChatHistoryHydration,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamLastEventAt,
  keeperThreads,
  liveSendOwnsRequest,
} from './keeper-state'
import {
  _resetCancelledKeeperThreadRequestsForTests,
  _resetKeeperThreadMessageSendGuardsForTests,
  _resetChatHydrationForTests,
  cancelActiveKeeperThreadMessage,
  cancelKeeperThreadRequest,
  dispatchKeeperInterjectAction,
  hydrateTrackedKeeperChatOperations,
  hydrateKeeperChatHistory,
  hydrateKeeperStatus,
  hydrateKeeperToolOutputs,
  loadFullKeeperHistory,
  noteKeeperChatAppended,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  refreshActiveKeeperChatHistory,
  refreshKnownKeeperChatHistories,
  selectKeeper,
  sendKeeperThreadMessage,
} from './keeper-actions'
import {
  _clearTrackedKeeperChatOperationsForTests,
  trackedKeeperChatOperationsForKeeper,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'
import { KEEPER_HISTORY_TAIL_MESSAGES } from './config/constants'
import { ApiRequestError, clearStoredToken, currentStoredTokenRevision, setStoredToken } from './api/core'
import { KeeperChatOperationMissingError } from './api/keeper-operation-error'
import {
  lookupToolCallOutput,
  resetToolCallOutputs,
  toolCallOutputHydrationContract,
  toolCallOutputHydrationFailureReason,
  toolCallOutputHydrationStatus,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from './tool-call-output-store'
import { _resetKeeperStreamBuffersForTests } from './keeper-stream'
import type { KeeperChatStreamEvent } from './api'
import type { ToolCallEntry } from './api/dashboard'
import type { KeeperStatusDetail } from './types'

beforeEach(() => {
  clearStoredToken()
  shellAuthSummary.value = { effective_role: 'admin' }
  fetchKeeperToolCalls.mockReset()
  fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
  resetToolCallOutputs()
  _resetKeeperStreamBuffersForTests()
})


function requiredFixture<T>(value: T | undefined): T {
  if (value === undefined) throw new Error('Expected fixture state to exist')
  return value
}

describe('operation cancellation admission', () => {
  beforeEach(() => {
    _resetCancelledKeeperThreadRequestsForTests()
    _clearTrackedKeeperChatOperationsForTests()
    cancelKeeperChatOperation.mockReset()
  })
  afterEach(() => _clearTrackedKeeperChatOperationsForTests())

  it.each(['resolve', 'reject'] as const)('does not settle cancellation across authentication replacement (%s)', async outcome => {
    setStoredToken('fixture-old')
    upsertTrackedKeeperChatOperation({ operationId: 'operation', keeperName: 'echo', message: 'input', submittedAt: 1 })
    let resolve!: (value: unknown) => void
    let reject!: (error: Error) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise((yes, no) => { resolve = yes; reject = no }))
    const cancel = cancelKeeperThreadRequest('echo', 'operation')
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope error' }
    if (outcome === 'reject') reject(new Error('old cancellation failed'))
    else resolve({ operationId: 'operation', state: { kind: 'cancelled', completedAt: 2 } })
    await cancel
    expect(keeperActionErrors.value.echo).toBe('current scope error')
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    clearStoredToken()
  })

  it('preserves a replacement cancellation owner when the old request settles', async () => {
    setStoredToken('fixture-old')
    let oldResolve!: (value: unknown) => void
    let currentResolve!: (value: unknown) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise(yes => { oldResolve = yes }))
      .mockReturnValueOnce(new Promise(yes => { currentResolve = yes }))
    const old = cancelKeeperThreadRequest('echo', 'operation')
    setStoredToken('fixture-new')
    const current = cancelKeeperThreadRequest('echo', 'operation')
    expect(cancelKeeperChatOperation).toHaveBeenCalledTimes(2)
    oldResolve({ operationId: 'operation', state: { kind: 'cancelled', completedAt: 2 } })
    expect(await old).toBeNull()
    expect(cancelKeeperThreadRequest('echo', 'operation')).toBe(current)
    currentResolve({ operationId: 'operation', state: { kind: 'cancelled', completedAt: 3 } })
    expect(await current).toBe('cancelled')
    clearStoredToken()
  })
})

describe('tool-output hydration credential scope', () => {
  afterEach(() => clearStoredToken())

  it('discards an Admin tail response after the credentials change', async () => {
    setStoredToken('fixture-admin')
    let complete!: (value: { entries: ToolCallEntry[] }) => void
    fetchKeeperToolCalls.mockReturnValueOnce(new Promise(resolve => { complete = resolve }))
    const hydration = hydrateKeeperToolOutputs('echo')
    setStoredToken('fixture-worker')
    complete({ entries: [{
      ts: 1, keeper: 'echo', tool: 'Read', input: {}, output: 'private',
      wire_outcome: 'ok', duration_ms: 1, execution_id: 'late-admin',
    }] })
    await hydration
    expect(lookupToolCallOutput('echo', 'late-admin')).toBeNull()
    expect(toolCallOutputHydrationStatus('echo')).toBe('idle')
  })

  it('does not mark the new credential scope failed when an older request rejects', async () => {
    setStoredToken('fixture-admin')
    let fail!: (reason: Error) => void
    fetchKeeperToolCalls.mockReturnValueOnce(new Promise((_resolve, reject) => { fail = reject }))
    const hydration = hydrateKeeperToolOutputs('echo')
    clearStoredToken()
    fail(new Error('old request failed'))
    await hydration
    expect(toolCallOutputHydrationStatus('echo')).toBe('idle')
    expect(toolCallOutputHydrationFailureReason('echo')).toBeNull()
  })
})

describe('noteKeeperChatAppended', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    activeKeeperName.value = ''
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
    vi.useFakeTimers()
  })

  afterEach(() => {
    activeKeeperName.value = ''
    vi.useRealTimers()
  })

  it('skips an un-hydrated keeper that is not the open panel', async () => {
    activeKeeperName.value = 'other'
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
  })

  it('re-hydrates the open keeper after a failed hydration when an append arrives', async () => {
    activeKeeperName.value = 'echo'
    // First hydration fails and rolls 'echo' back out of the hydrated set.
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
    expect(keeperChatHistoryErrors.value.echo).toContain('이전 대화 불러오기 실패')

    // A subsequent append for the open panel must converge (drop -> re-fetch)
    // rather than be skipped until the panel remounts.
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'msg-recovered-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
      { id: 'msg-recovered-assistant', role: 'assistant', content: 'recovered', ts: 1_780_000_000 },
    ])
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(2)
    expect(thread[1]?.text).toBe('recovered')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
  })

  it('preserves a newer action error when history recovers', async () => {
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    await hydrateKeeperChatHistory('echo')
    keeperActionErrors.value = { echo: keeperChatHistoryErrors.value.echo ?? null }
    fetchKeeperChatHistory.mockResolvedValueOnce([])

    await hydrateKeeperChatHistory('echo', { force: true })

    expect(keeperActionErrors.value.echo).toBe('이전 대화 불러오기 실패: HTTP 502')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
  })

  it('does not run a previous-auth notification after authentication changes before refresh admission', async () => {
    setStoredToken('fixture-before')
    fetchKeeperChatHistory.mockResolvedValue([{ id: 'initial', role: 'user', content: 'input', ts: 1 }])
    await hydrateKeeperChatHistory('echo')
    noteKeeperChatAppended('echo')
    setStoredToken('fixture-after')
    await Promise.resolve()
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
    noteKeeperChatAppended('echo')
    await Promise.resolve()
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    await vi.runAllTimersAsync()
  })

  it('starts broadcast refresh without waiting for a wall-clock quiet period', async () => {
    fetchKeeperChatHistory.mockResolvedValue([{ id: 'initial', role: 'user', content: 'input', ts: 1 }])
    await hydrateKeeperChatHistory('echo')
    noteKeeperChatAppended('echo')
    noteKeeperChatAppended('echo')
    await Promise.resolve()
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    await vi.runAllTimersAsync()
  })

  it('coalesces one event batch of appends into one forced refetch', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { id: 'msg-debounce-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    noteKeeperChatAppended('echo')
    noteKeeperChatAppended('echo')
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()

    // One additional fetch despite the once-per-keeper hydration guard
    // (force) and despite three push events (debounce).
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })

  it('waits for durable audio row ownership when two assistant replies share text', async () => {
    const first = { id: 'first-reply', role: 'assistant', content: 'same reply', ts: 1 }
    const second = { id: 'second-reply', role: 'assistant', content: 'same reply', ts: 2 }
    fetchKeeperChatHistory.mockResolvedValue([first, second])
    await hydrateKeeperChatHistory('echo')
    const audio = { token: 'second-clip', mime: 'audio/mpeg', message_text: 'same reply' }
    fetchKeeperChatHistory.mockResolvedValue([first, { ...second, audio }])
    noteKeeperChatAppended('echo', audio)
    expect(keeperThreads.value.echo?.every(row => row.audio == null)).toBe(true)
    await vi.runAllTimersAsync()
    expect(keeperThreads.value.echo?.find(row => row.id === 'first-reply')?.audio).toBeNull()
    expect(keeperThreads.value.echo?.find(row => row.id === 'second-reply')?.audio?.token).toBe('second-clip')
  })

  it('keeps audio unassociated across failed hydration and recovers on a later notification', async () => {
    const first = { id: 'first-reply', role: 'assistant', content: 'same reply', ts: 1 }
    const second = { id: 'second-reply', role: 'assistant', content: 'same reply', ts: 2 }
    fetchKeeperChatHistory.mockResolvedValue([first, second])
    await hydrateKeeperChatHistory('echo')
    const audio = { token: 'second-clip', mime: 'audio/mpeg', message_text: 'same reply' }
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('history unavailable'))
    noteKeeperChatAppended('echo', audio)
    await vi.runAllTimersAsync()
    expect(keeperThreads.value.echo?.every(row => row.audio == null)).toBe(true)
    fetchKeeperChatHistory.mockResolvedValue([first, { ...second, audio }])
    noteKeeperChatAppended('echo', audio)
    await vi.runAllTimersAsync()
    expect(keeperThreads.value.echo?.find(row => row.id === 'first-reply')?.audio).toBeNull()
    expect(keeperThreads.value.echo?.find(row => row.id === 'second-reply')?.audio?.token).toBe('second-clip')
  })

  it('still refreshes history when an audio clip is attached', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { id: 'msg-audio-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
      { id: 'msg-audio-assistant', role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
    ])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    noteKeeperChatAppended('echo', {
      token: 'live-clip',
      mime: 'audio/mpeg',
      message_text: 'hello there',
      duration_sec: 3,
    })
    await vi.runAllTimersAsync()

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })
})

describe('hydrateKeeperChatHistory', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    keeperHydrating.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
  })

  it('merges the server transcript into the thread', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { id: 'msg-hydrate-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
      { id: 'msg-hydrate-assistant', role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(2)
    expect(thread[0]?.delivery).toBe('history')
    expect(thread[0]?.streamContract).toMatchObject({
      source: 'rest_history',
      status: 'history_without_stream_events',
    })
    expect(thread[1]?.role).toBe('assistant')
  })

  it('replays a completed autonomous journal after the actual history hydration boundary', async () => {
    _resetKeeperAutonomousRecoveryForTests()
    vi.mocked(fetchKeeperTurnEvents).mockReset().mockResolvedValueOnce({ turnRef: 'history#1', hasMore: false,
      cursor: { sequence: 1, offset: 100 }, events: [
        { sequence: 0, timestamp: 1, event: { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
          value: { index: 0, delta: 'exposed historical reasoning' } } },
        { sequence: 1, timestamp: 1, event: { type: 'RUN_FINISHED' } },
      ] })
    fetchKeeperChatHistory.mockResolvedValueOnce([{ id: 'autonomous:history#1', role: 'assistant',
      content: 'canonical answer', ts: 1, autonomous_turn: { turn_id: 'history#1' } }])
    await hydrateKeeperChatHistory('echo')
    await vi.waitFor(() => expect(keeperThreads.value.echo?.[0]?.responseState).toMatchObject({ phase: 'terminal', lastSequence: 1 }))
    expect(fetchKeeperTurnEvents).toHaveBeenCalledWith('echo', 'history#1', { sequence: null, offset: 0 })
    expect(keeperThreads.value.echo?.[0]).toMatchObject({ text: 'canonical answer', delivery: 'history',
      traceSteps: [{ kind: 'think', text: 'exposed historical reasoning' }] })
    _resetKeeperAutonomousRecoveryForTests()
  })

  it('keeps backend stream contracts when hydrating server history', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      {
        id: 'msg-contract-assistant',
        role: 'assistant',
        content: 'done',
        ts: 1_780_000_000,
        turn_ref: 'trace-hydrate#2',
        stream_contract: {
          source: 'backend_turn_trace',
          status: 'backend_trace_join',
          turn_ref: 'trace-hydrate#2',
          trace_event_count: 2,
          reason: 'turn_ref joined to retained trajectory/internal-history events',
        },
      },
    ])

    await hydrateKeeperChatHistory('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread[0]?.streamContract).toEqual({
      source: 'backend_turn_trace',
      status: 'backend_trace_join',
      turnRef: 'trace-hydrate#2',
      traceEventCount: 2,
      reason: 'turn_ref joined to retained trajectory/internal-history events',
    })
  })

  it('fetches only once per keeper per page lifetime', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])

    await hydrateKeeperChatHistory('echo')
    await hydrateKeeperChatHistory('echo')

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })

  it('hydrates tool outputs even when the chat history is empty', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])

    await hydrateKeeperChatHistory('echo')

    expect(fetchKeeperToolCalls).toHaveBeenCalledWith('echo', 200)
  })

  it('bounds tool-output hydration to the returned output tail', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])
    fetchKeeperToolCalls.mockResolvedValue({
      entries: [
        {
          ts: 1_780_000_010,
          keeper: 'echo',
          tool: 'keeper_context_status',
          input: {},
          output: 'ok',
          wire_outcome: 'ok',
          duration_ms: 12,
          tool_use_id: 'toolu_recent',
        },
      ],
    })

    await hydrateKeeperChatHistory('echo')

    expect(toolCallOutputsCoveredSinceMs('echo')).toBe(1_780_000_010_000)
    expect(toolCallOutputsCoveredThroughMs('echo')).not.toBeNull()
  })

  it('does not treat an empty tool-output fetch as unbounded coverage', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])
    fetchKeeperToolCalls.mockResolvedValue({ entries: [] })

    await hydrateKeeperChatHistory('echo')

    expect(toolCallOutputsCoveredSinceMs('echo')).toBe(Number.POSITIVE_INFINITY)
    expect(toolCallOutputsCoveredThroughMs('echo')).not.toBeNull()
  })

  it('records tool-output hydration failures with a visible contract reason', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])
    fetchKeeperToolCalls.mockRejectedValueOnce(new Error('HTTP 502'))

    await hydrateKeeperChatHistory('echo')

    expect(toolCallOutputHydrationStatus('echo')).toBe('failed')
    expect(toolCallOutputHydrationFailureReason('echo')).toBe('HTTP 502')
    expect(toolCallOutputHydrationContract('echo')).toMatchObject({
      source: 'tool_calls_endpoint',
      status: 'failed',
      failureReason: 'HTTP 502',
    })
  })

  function historyRow(id: string) {
    return [{ id, role: 'user' as const, content: id, ts: 1_780_000_000 }]
  }

  function deferredHistory() {
    let resolve!: (history: ReturnType<typeof historyRow>) => void
    let reject!: (error: Error) => void
    const promise = new Promise<ReturnType<typeof historyRow>>((ok, fail) => {
      resolve = ok
      reject = fail
    })
    return { promise, resolve, reject }
  }

  it.each(['resolve', 'reject'] as const)('coalesces broadcasts during one history read into one follow-up (%s)', async outcome => {
    vi.useFakeTimers()
    try {
      fetchKeeperChatHistory.mockResolvedValueOnce(historyRow('initial'))
      await hydrateKeeperChatHistory('echo')
      const reading = deferredHistory()
      fetchKeeperChatHistory.mockReturnValueOnce(reading.promise).mockResolvedValueOnce(historyRow('latest'))
      noteKeeperChatAppended('echo')
      await Promise.resolve()
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
      noteKeeperChatAppended('echo')
      await Promise.resolve()
      noteKeeperChatAppended('echo')
      await Promise.resolve()
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
      if (outcome === 'resolve') reading.resolve(historyRow('superseded'))
      else reading.reject(new Error('superseded read failed'))
      await vi.runAllTimersAsync()
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(3)
      expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['latest'])
      expect(keeperHydrating.value.echo).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it.each(['resolve', 'reject'] as const)('invalidates an older history fetch on a newer broadcast (%s)', async outcome => {
    vi.useFakeTimers()
    try {
      fetchKeeperChatHistory.mockResolvedValueOnce(historyRow('initial'))
      await hydrateKeeperChatHistory('echo')
      const older = deferredHistory()
      const latest = deferredHistory()
      fetchKeeperChatHistory.mockReturnValueOnce(older.promise).mockReturnValueOnce(latest.promise)
      const pending = hydrateKeeperChatHistory('echo', { force: true })
      noteKeeperChatAppended('echo')
      if (outcome === 'resolve') older.resolve(historyRow('stale'))
      else older.reject(new Error('superseded failure'))
      await pending
      expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['initial'])
      expect(keeperChatHistoryErrors.value.echo).toBeNull()
      expect(keeperHydrating.value.echo).toBe(true)
      latest.resolve(historyRow('latest'))
      await vi.runAllTimersAsync()
      expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['latest'])
      expect(keeperHydrating.value.echo).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it.each([false, true])('settles a cancelled queued replacement without settling a new explicit read (newer=%s)', async newer => {
    vi.useFakeTimers()
    try {
      setStoredToken('fixture-before')
      fetchKeeperChatHistory.mockResolvedValueOnce(historyRow('initial'))
      await hydrateKeeperChatHistory('echo')
      const old = deferredHistory()
      const latest = deferredHistory()
      fetchKeeperChatHistory.mockReturnValueOnce(old.promise).mockReturnValueOnce(latest.promise)
      const pending = hydrateKeeperChatHistory('echo', { force: true })
      noteKeeperChatAppended('echo')
      setStoredToken('fixture-after')
      const replacement = newer ? hydrateKeeperChatHistory('echo', { force: true }) : null
      await Promise.resolve()
      old.resolve(historyRow('previous-auth'))
      await pending
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(newer ? 3 : 2)
      expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['initial'])
      expect(keeperHydrating.value.echo).toBe(newer)
      if (replacement) {
        latest.resolve(historyRow('current-auth'))
        await replacement
        expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['current-auth'])
        expect(keeperHydrating.value.echo).toBe(false)
      }
    } finally {
      vi.useRealTimers()
    }
  })

  it.each([false, true])('keeps running refresh ownership across auth replacement (new notification=%s)', async newer => {
    vi.useFakeTimers()
    try {
      setStoredToken('fixture-before')
      fetchKeeperChatHistory.mockResolvedValueOnce(historyRow('initial'))
      await hydrateKeeperChatHistory('echo')
      const old = deferredHistory()
      fetchKeeperChatHistory.mockReturnValueOnce(old.promise).mockResolvedValueOnce(historyRow('current-auth'))
      noteKeeperChatAppended('echo')
      await Promise.resolve()
      noteKeeperChatAppended('echo')
      setStoredToken('fixture-after')
      if (newer) noteKeeperChatAppended('echo')
      await Promise.resolve()
      old.resolve(historyRow('previous-auth'))
      await vi.runAllTimersAsync()
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(newer ? 3 : 2)
      expect(keeperThreads.value.echo?.map(row => row.id)).toEqual([newer ? 'current-auth' : 'initial'])
      expect(keeperChatHistoryErrors.value.echo ?? null).toBeNull()
      expect(keeperHydrating.value.echo).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it.each(['resolve', 'reject'] as const)('rejects history acquired under a replaced authentication revision (%s)', async outcome => {
    setStoredToken('fixture-before')
    const old = deferredHistory()
    fetchKeeperChatHistory.mockReturnValueOnce(old.promise).mockResolvedValueOnce(historyRow('current-auth'))
    const pending = hydrateKeeperChatHistory('echo')
    setStoredToken('fixture-after')
    if (outcome === 'resolve') old.resolve(historyRow('previous-auth'))
    else old.reject(new Error('previous-auth failure'))
    await pending
    expect(keeperThreads.value.echo ?? []).toEqual([])
    expect(keeperChatHistoryHydration.value.echo).not.toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo ?? null).toBeNull()
    await hydrateKeeperChatHistory('echo')
    expect(keeperThreads.value.echo?.map(row => row.id)).toEqual(['current-auth'])
  })

  it('keeps the latest failure when an older history succeeds', async () => {
    const older = deferredHistory()
    const latest = deferredHistory()
    fetchKeeperChatHistory.mockReturnValueOnce(older.promise).mockReturnValueOnce(latest.promise)
    const first = hydrateKeeperChatHistory(' echo ')
    const second = hydrateKeeperChatHistory('echo', { force: true })
    latest.reject(new Error('latest history failed'))
    await second
    const latestError = keeperChatHistoryErrors.value.echo
    expect(latestError).toContain('latest history failed')
    older.resolve(historyRow('stale-history'))
    await first
    expect(keeperChatHistoryErrors.value.echo).toBe(latestError)
    expect(keeperChatHistoryHydration.value.echo).toBe('failed')
    expect(keeperThreads.value.echo ?? []).toHaveLength(0)
    expect(fetchKeeperToolCalls).not.toHaveBeenCalled()
    fetchKeeperChatHistory.mockResolvedValueOnce([])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(3)
  })

  it('does not let an older failure retire a newer success', async () => {
    const older = deferredHistory()
    const latest = deferredHistory()
    fetchKeeperChatHistory.mockReturnValueOnce(older.promise).mockReturnValueOnce(latest.promise)
    const first = hydrateKeeperChatHistory('echo')
    const second = hydrateKeeperChatHistory('echo', { force: true })
    latest.resolve(historyRow('latest-history'))
    await second
    older.reject(new Error('stale history failed'))
    await first
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })

  it.each(['resolve', 'reject'] as const)('keeps the latest request pending after an older %s', async outcome => {
    const older = deferredHistory()
    const latest = deferredHistory()
    fetchKeeperChatHistory.mockReturnValueOnce(older.promise).mockReturnValueOnce(latest.promise)
    const first = hydrateKeeperChatHistory('echo')
    const second = hydrateKeeperChatHistory('echo', { force: true })
    if (outcome === 'resolve') older.resolve(historyRow('stale-history'))
    else older.reject(new Error('stale history failed'))
    await first
    expect(keeperHydrating.value.echo).toBe(true)
    expect(keeperChatHistoryHydration.value.echo).toBeUndefined()
    expect(keeperChatHistoryErrors.value.echo).toBeUndefined()
    expect(keeperThreads.value.echo ?? []).toHaveLength(0)
    latest.resolve(historyRow('latest-history'))
    await second
    expect(keeperHydrating.value.echo).toBe(false)
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['latest-history'])
  })

  it('does not merge a stale history after the latest success', async () => {
    const older = deferredHistory()
    const latest = deferredHistory()
    fetchKeeperChatHistory.mockReturnValueOnce(older.promise).mockReturnValueOnce(latest.promise)
    const first = hydrateKeeperChatHistory('echo')
    const second = hydrateKeeperChatHistory('echo', { force: true })
    latest.resolve(historyRow('latest-history'))
    await second
    older.resolve(historyRow('stale-history'))
    await first
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['latest-history'])
    expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(1)
  })

  it('allows a retry after a failed fetch', async () => {
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'msg-retry-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')
    expect(keeperChatHistoryErrors.value.echo).toContain('이전 대화 불러오기 실패')

    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(requiredFixture(keeperThreads.value.echo)).toHaveLength(1)
  })
})

describe('refreshActiveKeeperChatHistory', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    activeKeeperName.value = ''
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
    fetchKeeperChatHistory.mockResolvedValue([])
  })

  afterEach(() => {
    activeKeeperName.value = ''
  })

  it('does nothing when no keeper panel is open', () => {
    refreshActiveKeeperChatHistory({ force: true })
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
  })

  it('force re-fetches the open keeper transcript on reconnect recovery', async () => {
    activeKeeperName.value = 'echo'
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    refreshActiveKeeperChatHistory({ force: true })
    await Promise.resolve()
    await Promise.resolve()

    // Force bypasses the once-per-page guard so the missed replay-buffer gap
    // is re-fetched even though 'echo' is already hydrated.
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })

  it('recovers a missed completed turn for an inactive previously visited Keeper', async () => {
    _resetKeeperAutonomousRecoveryForTests()
    await hydrateKeeperChatHistory('inactive')
    await hydrateKeeperChatHistory('active')
    activeKeeperName.value = 'active'
    fetchKeeperChatHistory.mockReset().mockImplementation(name => Promise.resolve(name === 'inactive'
      ? [{ id: 'autonomous:missed#1', role: 'assistant', content: 'missed answer', ts: 1,
          autonomous_turn: { turn_id: 'missed#1' } }] : []))
    vi.mocked(fetchKeeperTurnEvents).mockReset().mockResolvedValueOnce({ turnRef: 'missed#1', hasMore: false,
      cursor: { sequence: 0, offset: 100 }, events: [{ sequence: 0, timestamp: 1, event: { type: 'RUN_FINISHED' } }] })
    await refreshKnownKeeperChatHistories()
    expect(fetchKeeperChatHistory).toHaveBeenCalledWith('active')
    expect(fetchKeeperChatHistory).toHaveBeenCalledWith('inactive')
    await vi.waitFor(() => expect(keeperThreads.value.inactive?.[0]?.responseState).toMatchObject({ phase: 'terminal' }))
    expect(keeperThreads.value.inactive?.[0]?.text).toBe('missed answer')
    _resetKeeperAutonomousRecoveryForTests()
  })
  it('refreshes an inactive pending history request and rejects its stale completion', async () => {
    let finishOld!: (rows: []) => void
    fetchKeeperChatHistory.mockReset().mockReturnValueOnce(new Promise(resolve => { finishOld = resolve }))
      .mockResolvedValueOnce([{ id: 'fresh-history', role: 'assistant', content: 'fresh answer', ts: 1 }])
    const old = hydrateKeeperChatHistory('inactive')
    await refreshKnownKeeperChatHistories()
    finishOld([])
    await old
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.inactive?.[0]?.text).toBe('fresh answer')
  })

  it('respects the hydration guard without force (route/periodic no-op)', async () => {
    activeKeeperName.value = 'echo'
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    refreshActiveKeeperChatHistory()
    await Promise.resolve()
    await Promise.resolve()

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })
})

describe('sendKeeperThreadMessage operation stream', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    keeperStreamLastEventAt.value = {}
    _resetChatHydrationForTests()
    _clearTrackedKeeperChatOperationsForTests()
    _resetKeeperThreadMessageSendGuardsForTests()
    _resetLiveSendRequestOwnersForTests()
    _resetActiveKeeperStreamsForTests()
    _resetCancelledKeeperThreadRequestsForTests()
    streamKeeperMessage.mockReset()
    cancelKeeperChatOperation.mockReset()
    fetchKeeperChatOperation.mockReset()
    fetchKeeperChatHistory.mockReset()
  })

  function completeStream(
    reply: string,
    state: 'Queued' | 'Running' = 'Running',
  ) {
    return async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: {
          operation_id: opts.operationId,
          state,
          queued_count: state === 'Queued' ? 1 : 0,
        },
      })
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: reply })
      opts.onEvent({ type: 'RUN_FINISHED' })
      return { terminal: true }
    }
  }

  it('preserves authored request blocks and the completed reply', async () => {
    const text = '    첫 줄\nSKILL.md 설명\n\n\n끝  \n\n'
    streamKeeperMessage.mockImplementation(completeStream(text))

    await sendKeeperThreadMessage('echo', text)

    expect(streamKeeperMessage).toHaveBeenCalledWith('echo', text, expect.objectContaining({
      userBlocks: [{ type: 'text', text }],
    }))
    expect(keeperThreads.value.echo?.filter(entry => entry.role === 'user').at(-1)?.text).toBe(text)
    expect(keeperThreads.value.echo?.filter(entry => entry.role === 'assistant').at(-1)?.text).toBe(text)
  })

  it('does not apply old stream events or reconcile under replacement credentials', async () => {
    setStoredToken('fixture-old')
    let emit!: (event: KeeperChatStreamEvent) => void
    let finish!: (outcome: { terminal: boolean }) => void
    streamKeeperMessage.mockImplementationOnce((_name, _message, options) => {
      emit = options.onEvent
      return new Promise(resolve => { finish = resolve })
    })
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope error' }
    const oldEvents: KeeperChatStreamEvent[] = [
      { type: 'TEXT_MESSAGE_CONTENT', messageId: 'old-message', delta: 'old response' },
      { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: 'old reasoning' } },
      { type: 'TOOL_CALL_START', toolCallId: 'old-tool', toolCallName: 'Read',
        toolStreamScope: 0, toolCallBlockIndex: 0 },
    ]
    for (const event of oldEvents) {
      try { emit(event) } catch {}
    }
    finish({ terminal: true })
    await send
    expect(keeperThreads.value.echo?.some(entry => entry.text.includes('old response'))).toBe(false)
    expect(keeperThreads.value.echo?.some(entry => entry.role === 'tool')).toBe(false)
    expect(keeperThreads.value.echo?.some(entry => entry.traceSteps?.some(step => step.kind === 'think'))).toBe(false)
    expect(keeperActionErrors.value.echo).toBe('current scope error')
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
    expect(cancelKeeperChatOperation).not.toHaveBeenCalled()
    expect(keeperThreads.value.echo?.find(entry => entry.role === 'user')).toMatchObject({ text: 'input', delivery: 'interrupted' })
    clearStoredToken()
  })

  it('keeps accepted partial observations available for recovery after authentication withdrawal', async () => {
    setStoredToken('fixture-old')
    let finish!: (outcome: { terminal: boolean }) => void
    streamKeeperMessage.mockImplementationOnce((_name, _message, options) => {
      options.onEvent({ type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: options.operationId, state: 'Running', queued_count: 0 } })
      options.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'admitted partial' })
      return new Promise(resolve => { finish = resolve })
    })
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope error' }
    finish({ terminal: false })
    await send
    expect(keeperThreads.value.echo?.find(entry => entry.role === 'user')?.delivery).toBe('delivered')
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft).toMatchObject({
      rawText: 'admitted partial', delivery: 'interrupted', streamState: null,
    })
    expect(keeperActionErrors.value.echo).toBe('current scope error')
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
    expect(cancelKeeperChatOperation).not.toHaveBeenCalled()
    clearStoredToken()
  })

  it('accepts the HTTP admission established after initial credential bootstrap', async () => {
    streamKeeperMessage.mockImplementationOnce(async (_name, _message, options) => {
      setStoredToken('fixture-dev', { source: 'dev', actor: 'dashboard', role: 'admin' })
      options.onAdmission({ keeperName: 'echo', operationId: options.operationId,
        authRevision: currentStoredTokenRevision() })
      options.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'admitted response' })
      options.onEvent({ type: 'RUN_FINISHED' })
      return { terminal: true }
    })
    await sendKeeperThreadMessage('echo', 'input')
    expect(keeperThreads.value.echo?.find(entry => entry.role === 'assistant')?.rawText).toBe('admitted response')
    clearStoredToken()
  })

  it('does not release a newer send when an older authentication scope settles', async () => {
    setStoredToken('fixture-old')
    let finishOld!: (outcome: { terminal: boolean }) => void
    let finishCurrent!: (outcome: { terminal: boolean }) => void
    let currentEvent!: (event: KeeperChatStreamEvent) => void
    streamKeeperMessage.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
      .mockImplementationOnce((_name, _message, options) => {
        currentEvent = options.onEvent
        options.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'current answer' })
        return new Promise(resolve => { finishCurrent = resolve })
      })
    const old = sendKeeperThreadMessage('echo', 'old input').catch(error => error)
    setStoredToken('fixture-new')
    const current = sendKeeperThreadMessage('echo', 'new input')
    finishOld({ terminal: false })
    await old
    expect(keeperSending.value.echo).toBe(true)
    currentEvent({ type: 'RUN_FINISHED' })
    finishCurrent({ terminal: true })
    await current
    expect(keeperThreads.value.echo?.some(entry => entry.rawText === 'current answer' && entry.delivery === 'delivered')).toBe(true)
    expect(keeperSending.value.echo).toBe(false)
    clearStoredToken()
  })

  it.each(['resolve', 'reject'] as const)('preserves current action error when failed-send history becomes stale (%s)', async outcome => {
    setStoredToken('fixture-old')
    const streamFailure = new Error('old stream failed')
    streamKeeperMessage.mockRejectedValueOnce(streamFailure)
    let resolve!: (rows: unknown[]) => void
    let reject!: (error: Error) => void
    fetchKeeperChatHistory.mockReturnValueOnce(new Promise((yes, no) => { resolve = yes; reject = no }))
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    await vi.waitFor(() => expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1))
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope action error' }
    if (outcome === 'resolve') resolve([])
    else reject(new Error('old history failed'))
    expect(await send).toBe(streamFailure)
    expect(keeperActionErrors.value.echo).toBe('current scope action error')
    clearStoredToken()
  })

  it('preserves current errors when credentials change between canonical history admission and caller settlement', async () => {
    setStoredToken('fixture-old')
    const streamFailure = new Error('old stream failed')
    let operationId = ''
    streamKeeperMessage.mockImplementationOnce(async (_name, _message, options) => {
      operationId = options.operationId
      throw streamFailure
    })
    let resolve!: (rows: unknown[]) => void
    fetchKeeperChatHistory.mockReturnValueOnce(new Promise(yes => { resolve = yes }))
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    await vi.waitFor(() => expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1))
    resolve([
      { id: 'canonical-user', role: 'user', content: 'input', ts: 1,
        delivery_provenance: operationDeliveryProvenance(operationId, 'accepted_user'), delivery_provenance_status: 'valid' },
      { id: 'canonical-assistant', role: 'assistant', content: 'answer', ts: 2,
        delivery_provenance: operationDeliveryProvenance(operationId, 'terminal_result'), delivery_provenance_status: 'valid' },
    ])
    queueMicrotask(() => {
      setStoredToken('fixture-new')
      keeperActionErrors.value = { echo: 'current scope action error' }
    })
    expect(await send).toBe(streamFailure)
    expect(keeperActionErrors.value.echo).toBe('current scope action error')
    clearStoredToken()
  })

  it('preserves text when user blocks supply the message fallback', async () => {
    const text = '    블록의 첫 줄\n\n끝  '
    streamKeeperMessage.mockImplementation(completeStream('ok'))

    await sendKeeperThreadMessage('echo', '  ', { userBlocks: [{ type: 'text', text }] })

    expect(streamKeeperMessage).toHaveBeenCalledWith('echo', text, expect.objectContaining({
      userBlocks: [{ type: 'text', text }],
    }))
  })

  it('submits repeated messages as distinct durable operation ids', async () => {
    streamKeeperMessage.mockImplementation(completeStream('ok'))

    await Promise.all([
      sendKeeperThreadMessage('echo', 'same'),
      sendKeeperThreadMessage('echo', 'same'),
    ])

    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
    const operationIds = streamKeeperMessage.mock.calls.map(call => call[2].operationId)
    expect(new Set(operationIds).size).toBe(2)
    expect(operationIds.every(id => id.startsWith('kmsg-'))).toBe(true)
  })

  it('keeps one row per turn when the stream dies before the operation is accepted', async () => {
    // No KEEPER_CHAT_OPERATION_ACCEPTED: this is the disconnected-socket case,
    // where the accept handler never runs and the placeholders are left with
    // whatever identity they were created with. The backend still accepted the
    // message, so history comes back carrying the operation's request id.
    let submittedOperationId = ''
    streamKeeperMessage.mockImplementation(
      async (_name: string, _message: string, opts: { operationId: string }) => {
        submittedOperationId = opts.operationId
        return { terminal: true }
      },
    )

    await sendKeeperThreadMessage('echo', 'hi')

    fetchKeeperChatHistory.mockResolvedValue([
      {
        id: 'msg-disconnected-user',
        role: 'user',
        content: 'hi',
        ts: 1_780_000_000,
        delivery_provenance: {
          delivery_key: { kind: 'operation', operation_id: submittedOperationId },
          transcript_slot: { kind: 'accepted_user' },
        },
        delivery_provenance_status: 'valid',
      },
      {
        id: 'msg-disconnected-assistant',
        role: 'assistant',
        content: 'hello there',
        ts: 1_780_000_001,
        delivery_provenance: {
          delivery_key: { kind: 'operation', operation_id: submittedOperationId },
          transcript_slot: { kind: 'terminal_result' },
        },
        delivery_provenance_status: 'valid',
      },
    ])
    await hydrateKeeperChatHistory('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread.filter(entry => entry.role === 'user')).toHaveLength(1)
    expect(thread.filter(entry => entry.role === 'assistant')).toHaveLength(1)
  })

  it('does not abort the running operation when a second operation is accepted', async () => {
    const streams: Array<{
      operationId: string
      signal: AbortSignal
      resolve: (value: { terminal: boolean }) => void
    }> = []
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        signal: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: {
          operation_id: opts.operationId,
          state: streams.length === 0 ? 'Running' : 'Queued',
          queued_count: streams.length,
        },
      })
      return new Promise<{ terminal: boolean }>(resolve => {
        streams.push({ operationId: opts.operationId, signal: opts.signal, resolve })
      })
    })

    const first = sendKeeperThreadMessage('echo', 'first')
    await Promise.resolve()
    const second = sendKeeperThreadMessage('echo', 'second')
    await Promise.resolve()

    expect(streams).toHaveLength(2)
    expect(streams[0]?.signal.aborted).toBe(false)
    expect(streams[1]?.signal.aborted).toBe(false)

    streams[0]?.resolve({ terminal: false })
    streams[1]?.resolve({ terminal: false })
    fetchKeeperChatOperation.mockResolvedValue({
      operationId: 'terminal',
      state: { kind: 'cancelled', completedAt: 1 },
    })
    await Promise.allSettled([first, second])
  })

  it('releases only the pre-acceptance stream that ended', async () => {
    const streams: Array<{
      operationId: string
      resolve: (value: { terminal: boolean }) => void
    }> = []
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: { operationId: string },
    ) => new Promise<{ terminal: boolean }>(resolve => {
      streams.push({ operationId: opts.operationId, resolve })
    }))

    const first = sendKeeperThreadMessage('echo', 'first')
    await Promise.resolve()
    const second = sendKeeperThreadMessage('echo', 'second')
    await Promise.resolve()

    const firstId = streams[0]?.operationId ?? ''
    const secondId = streams[1]?.operationId ?? ''
    expect(liveSendOwnsRequest(firstId)).toBe(true)
    expect(liveSendOwnsRequest(secondId)).toBe(true)

    streams[0]?.resolve({ terminal: false })
    await first

    expect(liveSendOwnsRequest(firstId)).toBe(false)
    expect(liveSendOwnsRequest(secondId)).toBe(true)

    streams[1]?.resolve({ terminal: false })
    await second
  })

  it('keeps authored input sending until the operation acceptance receipt', async () => {
    let options!: { operationId: string; onEvent: (event: KeeperChatStreamEvent) => void }
    let finish!: (value: { terminal: boolean }) => void
    streamKeeperMessage.mockImplementationOnce((_name, _message, admitted) => {
      options = admitted
      return new Promise(resolve => { finish = resolve })
    })
    const send = sendKeeperThreadMessage('echo', 'original input')
    const user = () => keeperThreads.value.echo?.find(entry => entry.role === 'user')
    expect(user()?.text).toBe('original input')
    expect(user()?.delivery).toBe('sending')
    options.onEvent({ type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: options.operationId, state: 'Running', queued_count: 0 } })
    expect(user()?.delivery).toBe('delivered')
    finish({ terminal: false })
    await send
  })

  it('cancels the FIFO-head operation by exact operation id', async () => {
    let acceptedOperationId = ''
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        signal: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      acceptedOperationId = opts.operationId
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: {
          operation_id: opts.operationId,
          state: 'Running',
          queued_count: 0,
        },
      })
      return new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal.addEventListener('abort', () => {
          const error = new Error('Aborted')
          error.name = 'AbortError'
          reject(error)
        }, { once: true })
      })
    })
    cancelKeeperChatOperation.mockImplementation(async (
      _keeperName: string,
      operationId: string,
    ) => ({
      operationId,
      sequence: '1',
      createdAt: 1,
      input: null,
      state: { kind: 'cancelled', completedAt: 2 },
    }))

    const send = sendKeeperThreadMessage('echo', 'cancel me').catch(() => undefined)
    await Promise.resolve()
    await cancelActiveKeeperThreadMessage('echo')
    await send
    await Promise.resolve()

    expect(cancelKeeperChatOperation).toHaveBeenCalledWith('echo', acceptedOperationId)
  })

  it('waits for server cancellation confirmation', async () => {
    let acceptedOperationId = ''
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        signal: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      acceptedOperationId = opts.operationId
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: {
          operation_id: opts.operationId,
          state: 'Running',
          queued_count: 0,
        },
      })
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Partial answer' })
      return new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal.addEventListener('abort', () => {
          const error = new Error('Aborted')
          error.name = 'AbortError'
          reject(error)
        }, { once: true })
      })
    })
    let confirm!: (value: unknown) => void
    cancelKeeperChatOperation.mockImplementation(() => new Promise(resolve => { confirm = resolve }))

    const send = sendKeeperThreadMessage('echo', 'cancel me').catch(() => undefined)
    await Promise.resolve()
    await cancelActiveKeeperThreadMessage('echo')
    await Promise.resolve()
    expect((keeperThreads.value.echo ?? []).some(entry => entry.delivery === 'cancelled')).toBe(false)
    expect((keeperThreads.value.echo ?? []).some(entry => entry.text === 'Partial answer' && entry.streamState === 'cancelling')).toBe(true)
    confirm({ operationId: acceptedOperationId, sequence: '1', createdAt: 1, input: null,
      state: { kind: 'cancelled', completedAt: 2 } })
    await send
    await Promise.resolve()

    expect(cancelKeeperChatOperation).toHaveBeenCalledWith('echo', acceptedOperationId)
  })

  it('applies cancellation after the failed stream finishes history reconciliation', async () => {
    let operationId = ''
    streamKeeperMessage.mockImplementationOnce(async (_name, _message, options) => {
      operationId = options.operationId
      options.onEvent({ type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: operationId, state: 'Running', queued_count: 0 } })
      throw new Error('transport failed')
    })
    let finishHistory!: (value: unknown) => void
    fetchKeeperChatHistory.mockReturnValueOnce(new Promise(resolve => { finishHistory = resolve }))
    let confirm!: (value: unknown) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise(resolve => { confirm = resolve }))
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    await vi.waitFor(() => expect(fetchKeeperChatHistory).toHaveBeenCalled())
    await cancelActiveKeeperThreadMessage('echo')
    finishHistory([])
    await send
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    confirm({ operationId, state: { kind: 'cancelled', completedAt: 2 } })
    await vi.waitFor(() => expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(0))
    expect(keeperActionErrors.value.echo).toBeNull()
  })

  it('keeps accepted recovery when authentication changes during server cancellation', async () => {
    setStoredToken('fixture-old')
    let operationId = ''
    streamKeeperMessage.mockImplementationOnce((_name, _message, options) => {
      operationId = options.operationId
      options.onEvent({ type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: operationId, state: 'Running', queued_count: 0 } })
      options.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'partial answer' })
      return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => {
        reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }))
      }, { once: true }))
    })
    let confirm!: (value: unknown) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise(resolve => { confirm = resolve }))
    const send = sendKeeperThreadMessage('echo', 'input').catch(error => error)
    await cancelActiveKeeperThreadMessage('echo')
    await Promise.resolve()
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope error' }
    confirm({ operationId, state: { kind: 'cancelled', completedAt: 2 } })
    await send
    expect(keeperActionErrors.value.echo).toBe('current scope error')
    expect(fetchKeeperChatOperation).not.toHaveBeenCalled()
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.rawText).toBe('partial answer')
    clearStoredToken()
  })

  it('aborts locally without server cancel before operation acceptance', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: { signal: AbortSignal },
    ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
      opts.signal.addEventListener('abort', () => {
        const error = new Error('Aborted')
        error.name = 'AbortError'
        reject(error)
      }, { once: true })
    }))

    const send = sendKeeperThreadMessage('echo', 'cancel before accept').catch(() => undefined)
    await Promise.resolve()
    await cancelActiveKeeperThreadMessage('echo')
    await send

    expect(cancelKeeperChatOperation).not.toHaveBeenCalled()
  })

  it('streams thinking, tool use, and final text after operation acceptance', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: opts.operationId, state: 'Running', queued_count: 0 },
      })
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: 'checking' },
      })
      opts.onEvent({
        type: 'TOOL_CALL_START',
        toolStreamScope: 0,
        toolCallBlockIndex: 0,
        toolCallId: 'tool-1',
        toolCallName: 'lookup',
      })
      opts.onEvent({
        type: 'TOOL_CALL_END',
        toolStreamScope: 0,
        toolCallBlockIndex: 0,
        toolCallId: 'tool-1',
      })
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_TOOL_RESULT_READY',
        value: {
          toolStreamScope: 0,
          toolCallBlockIndex: 0,
          toolCallId: 'tool-1',
          executionId: 'exec-tool-1',
        },
      })
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'done' })
      opts.onEvent({ type: 'RUN_FINISHED' })
      return { terminal: true }
    })

    await sendKeeperThreadMessage('echo', 'use a tool')

    const assistant = (keeperThreads.value.echo ?? [])
      .find(entry => entry.role === 'assistant' && entry.source === 'direct_assistant')
    expect(assistant?.text).toBe('done')
    expect(assistant?.traceSteps).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'think', text: 'checking' }),
      expect.objectContaining({ kind: 'tool', toolCallId: 'tool-1' }),
    ]))
  })
})


const VALID_DIAGNOSTIC_RAW = {
  health_state: 'healthy',
  next_action_path: 'probe',
  last_reply_status: 'fresh',
}

const cachedDetail = (name: string): KeeperStatusDetail => ({
  name,
  diagnostic: null,
  history: [],
  rawText: 'cached',
  loadedAt: '2026-06-10T00:00:00Z',
})

describe('selectKeeper', () => {
  it('sets activeKeeperName with the trimmed value', () => {
    selectKeeper('  echo  ')
    expect(activeKeeperName.value).toBe('echo')
  })

  it('sets the empty string when the name is all whitespace', () => {
    selectKeeper('   \t\n   ')
    expect(activeKeeperName.value).toBe('')
  })
})

describe('dispatchKeeperInterjectAction', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    streamKeeperMessage.mockReset()
  })

  it('rejects when keeperName is empty after trim', async () => {
    await expect(
      dispatchKeeperInterjectAction({ kind: 'send', keeperName: '  ', message: 'hello' }),
    ).rejects.toThrow('INTERJECT requires an active keeper.')
  })

  it('rejects when kind is send and the message is empty after trim', async () => {
    await expect(
      dispatchKeeperInterjectAction({ kind: 'send', keeperName: 'echo', message: '  ' }),
    ).rejects.toThrow('INTERJECT send requires a message.')
  })

  it('trims the keeper name while preserving the interject message', async () => {
    streamKeeperMessage.mockResolvedValue({ terminal: true })

    await dispatchKeeperInterjectAction({ kind: 'send', keeperName: '  echo  ', message: '  hi  ' })

    expect(streamKeeperMessage).toHaveBeenCalledWith('echo', '  hi  ', expect.objectContaining({
      onEvent: expect.any(Function),
    }))
  })

  it('rejects kinds that still need a backend operator action', async () => {
    await expect(
      dispatchKeeperInterjectAction({ kind: 'approve', keeperName: 'echo' }),
    ).rejects.toThrow(/requires a keeper-scoped backend operator action/)
  })
})

describe('hydrateKeeperStatus', () => {
  beforeEach(() => {
    keeperStatusDetails.value = {}
    keeperActionErrors.value = {}
    keeperHydrating.value = {}
    callMcpTool.mockReset()
  })

  it('returns null for an empty name without calling MCP', async () => {
    expect(await hydrateKeeperStatus('  ')).toBeNull()
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('returns the cached detail without an MCP call when force is false', async () => {
    const existing = cachedDetail('echo')
    keeperStatusDetails.value = { echo: existing }

    expect(await hydrateKeeperStatus('echo')).toBe(existing)
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('re-fetches when force is true despite a cached detail', async () => {
    keeperStatusDetails.value = { echo: cachedDetail('echo') }
    callMcpTool.mockResolvedValue('{"name":"echo"}')

    await hydrateKeeperStatus('echo', true)

    expect(callMcpTool).toHaveBeenCalledTimes(1)
  })

  it('calls masc_keeper_status with the fast/no-history options', async () => {
    callMcpTool.mockResolvedValue('{"name":"echo"}')

    const detail = await hydrateKeeperStatus('  echo  ')

    expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_status', {
      name: 'echo',
      fast: true,
      include_context: false,
      include_metrics_overview: false,
      include_history_tail: false,
      tail_turns: 0,
      tail_messages: 0,
    })
    expect(detail).not.toBeNull()
    expect(keeperStatusDetails.value.echo).toBeDefined()
  })

  it('records the error, returns null, and clears the hydrating flag on failure', async () => {
    callMcpTool.mockRejectedValue(new Error('MCP timeout'))

    expect(await hydrateKeeperStatus('echo')).toBeNull()
    expect(keeperActionErrors.value.echo).toBe('MCP timeout')
    expect(keeperHydrating.value.echo).toBe(false)
  })
})

describe('loadFullKeeperHistory', () => {
  beforeEach(() => {
    keeperStatusDetails.value = {}
    keeperHydrating.value = {}
    callMcpTool.mockReset()
  })

  it('returns early for an empty name', async () => {
    await loadFullKeeperHistory('  ')
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('requests only the history tail (heavy sections stay disabled)', async () => {
    callMcpTool.mockResolvedValue('{"name":"echo"}')

    await loadFullKeeperHistory('echo')

    expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_status', {
      name: 'echo',
      fast: false,
      include_context: false,
      include_metrics_overview: false,
      include_history_tail: true,
      tail_turns: 0,
      tail_messages: KEEPER_HISTORY_TAIL_MESSAGES,
    })
    expect(keeperStatusDetails.value.echo).toBeDefined()
  })

  it('swallows MCP failures and clears the hydrating flag', async () => {
    callMcpTool.mockRejectedValue(new Error('history fetch failed'))

    await expect(loadFullKeeperHistory('echo')).resolves.toBeUndefined()
    expect(keeperHydrating.value.echo).toBe(false)
  })

  it('degrades gracefully on a malformed JSON response', async () => {
    callMcpTool.mockResolvedValue('{{{ bad json }')

    await expect(loadFullKeeperHistory('echo')).resolves.toBeUndefined()
    expect(keeperStatusDetails.value.echo?.rawText).toBe('{{{ bad json }')
  })
})

describe('probeKeeperRuntime', () => {
  beforeEach(() => {
    keeperStatusDetails.value = {}
    keeperActionErrors.value = {}
    keeperProbing.value = {}
    keeperThreads.value = {}
    runOperatorAction.mockReset()
    refreshDashboard.mockClear()
    invalidateDashboardCache.mockClear()
  })

  it('returns null for an empty name without an operator action', async () => {
    expect(await probeKeeperRuntime('  ', 'operator')).toBeNull()
    expect(runOperatorAction).not.toHaveBeenCalled()
  })

  it('sends keeper_probe and stores the returned diagnostic', async () => {
    runOperatorAction.mockResolvedValue({
      status: 'ok',
      result: { status: 'running', diagnostic: VALID_DIAGNOSTIC_RAW },
    })

    const diagnostic = await probeKeeperRuntime('echo', 'operator')

    expect(runOperatorAction).toHaveBeenCalledWith({
      actor: 'operator',
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: 'echo',
      payload: {},
    })
    expect(diagnostic?.health_state).toBe('healthy')
    expect(keeperStatusDetails.value.echo?.diagnostic?.health_state).toBe('healthy')
    expect(invalidateDashboardCache).toHaveBeenCalled()
    expect(refreshDashboard).toHaveBeenCalledWith({ force: true })
  })

  it('returns null when the probe result carries no valid diagnostic', async () => {
    runOperatorAction.mockResolvedValue({ status: 'ok', result: {} })

    expect(await probeKeeperRuntime('echo', 'operator')).toBeNull()
    expect(keeperStatusDetails.value.echo).toBeUndefined()
  })

  it('records the error, rethrows, and clears the probing flag on failure', async () => {
    runOperatorAction.mockRejectedValue(new Error('probe timeout'))

    await expect(probeKeeperRuntime('echo', 'operator')).rejects.toThrow('probe timeout')
    expect(keeperActionErrors.value.echo).toBe('probe timeout')
    expect(keeperProbing.value.echo).toBe(false)
  })
})

describe('recoverKeeperRuntime', () => {
  beforeEach(() => {
    keeperStatusDetails.value = {}
    keeperActionErrors.value = {}
    keeperRecovering.value = {}
    keeperThreads.value = {}
    runOperatorAction.mockReset()
    refreshDashboard.mockClear()
    invalidateDashboardCache.mockClear()
  })

  it('returns null for an empty name without an operator action', async () => {
    expect(await recoverKeeperRuntime('  ', 'operator')).toBeNull()
    expect(runOperatorAction).not.toHaveBeenCalled()
  })

  it('sends keeper_recover and returns the post-recovery diagnostic', async () => {
    runOperatorAction.mockResolvedValue({
      status: 'ok',
      result: { recovered: true, after: VALID_DIAGNOSTIC_RAW },
    })

    const after = await recoverKeeperRuntime('echo', 'operator')

    expect(runOperatorAction).toHaveBeenCalledWith({
      actor: 'operator',
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: 'echo',
      payload: {},
    })
    expect(after?.health_state).toBe('healthy')
    expect(keeperStatusDetails.value.echo?.diagnostic?.health_state).toBe('healthy')
  })

  it('returns null when recovery yields no after-diagnostic', async () => {
    runOperatorAction.mockResolvedValue({ status: 'ok', result: { recovered: false } })

    expect(await recoverKeeperRuntime('echo', 'operator')).toBeNull()
  })

  it('records the error, rethrows, and clears the recovering flag on failure', async () => {
    runOperatorAction.mockRejectedValue(new Error('recover timeout'))

    await expect(recoverKeeperRuntime('echo', 'operator')).rejects.toThrow('recover timeout')
    expect(keeperActionErrors.value.echo).toBe('recover timeout')
    expect(keeperRecovering.value.echo).toBe(false)
  })
})


describe('restored chat operation outcome', () => {
  it('restores pending producer speech while operation lookup is unavailable', async () => {
    const pending = { text: 'checking result', timestamp: 1,
      owner: { content_generation: 1, stream_scope: 0 }, scope: null }
    upsertTrackedKeeperChatOperation({ operationId: 'restored-op', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'canonical answer', rawText: 'canonical answer', delivery: 'history', streamState: null,
        producerSayingReplay: pending, producerTraceBoundary: 2,
        traceSteps: [{ kind: 'think', text: 'provided reasoning' }],
        publishedTraceSteps: [{ kind: 'think', text: '', contentWithheld: true }],
        responseState: { ...initialKeeperResponseState, lastSequence: 2 } } })
    fetchKeeperChatOperation.mockRejectedValue(new Error('lookup unavailable'))
    await hydrateTrackedKeeperChatOperations('echo')
    expect(keeperThreads.value.echo?.find(entry => entry.role === 'assistant')).toMatchObject({
      text: 'canonical answer', producerSayingReplay: pending, producerTraceBoundary: 2,
      traceSteps: [{ kind: 'think', text: 'provided reasoning' }],
      publishedTraceSteps: [{ kind: 'think', text: '', contentWithheld: true }],
    })
  })
  beforeEach(() => {
    _resetChatHydrationForTests()
    _resetLiveSendRequestOwnersForTests()
    _clearTrackedKeeperChatOperationsForTests()
    keeperThreads.value = {}
    fetchKeeperChatOperation.mockReset()
    fetchKeeperChatHistory.mockReset()
    fetchKeeperChatHistory.mockResolvedValue([])
  })
  afterEach(() => _clearTrackedKeeperChatOperationsForTests())

  function storeDraft(): void {
    upsertTrackedKeeperChatOperation({ operationId: 'restored-op', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'partial authored answer', rawText: 'partial authored answer', delivery: 'streaming',
        streamState: 'streaming', timestamp: '2026-10-11T00:00:00Z', traceSteps: [{ kind: 'think', text: 'exposed reasoning' }] } })
  }

  it.each([
    ['echo', 'restored-op', true],
    ['other', 'restored-op', false],
    ['echo', 'other-operation', false],
  ] as const)('uses a missing-operation receipt only for its exact identity (%s, %s)', async (keeper, operationId, matches) => {
    storeDraft()
    const missing = new KeeperChatOperationMissingError(keeper, operationId,
      new ApiRequestError({ method: 'GET', path: '/lookup', status: 404, detail: 'fixture missing receipt' }))
    fetchKeeperChatOperation.mockRejectedValueOnce(missing)
    await hydrateTrackedKeeperChatOperations('echo')
    if (matches) {
      expect(keeperActionErrors.value.echo).toContain('서버에서 요청을 찾을 수 없습니다')
      expect(keeperActionErrors.value.echo).not.toContain('서버 재시작')
    } else expect(keeperActionErrors.value.echo).toContain(missing.message)
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
  })

  it.each([
    new Error('transport failed for /chat/operations/restored-op; cached diagnostic: unknown_operation'),
    Object.assign(new Error('route unavailable'), { method: 'GET', status: 404, path: '/api/v1/keepers/echo/chat/operations/restored-op' }),
  ])('does not infer lost operation from prose or an unclassified HTTP error', async error => {
    storeDraft()
    fetchKeeperChatOperation.mockRejectedValueOnce(error)
    await hydrateTrackedKeeperChatOperations('echo')
    expect(keeperActionErrors.value.echo).toContain(error.message)
    expect(keeperActionErrors.value.echo).not.toContain('서버 재시작')
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
  })

  it.each(['resolve', 'reject'] as const)('rejects operation lookup from replaced authentication (%s)', async outcome => {
    storeDraft()
    setStoredToken('fixture-old')
    let resolve!: (value: unknown) => void
    let reject!: (error: Error) => void
    fetchKeeperChatOperation.mockReturnValueOnce(new Promise((yes, no) => { resolve = yes; reject = no }))
    const recovery = hydrateTrackedKeeperChatOperations('echo')
    setStoredToken('fixture-new')
    keeperActionErrors.value = { echo: 'current scope error' }
    if (outcome === 'reject') reject(new Error('old lookup failed'))
    else resolve({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'result' } })
    await recovery
    expect(keeperActionErrors.value.echo).toBe('current scope error')
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.delivery).toBe('streaming')
    clearStoredToken()
  })

  it('admits current-auth recovery while the previous-auth lookup is pending without losing its owner', async () => {
    storeDraft()
    setStoredToken('fixture-old')
    let oldResolve!: (value: unknown) => void
    let currentResolve!: (value: unknown) => void
    fetchKeeperChatOperation.mockReturnValueOnce(new Promise(yes => { oldResolve = yes }))
      .mockReturnValueOnce(new Promise(yes => { currentResolve = yes }))
    const old = hydrateTrackedKeeperChatOperations('echo')
    setStoredToken('fixture-new')
    const current = hydrateTrackedKeeperChatOperations('echo')
    expect(fetchKeeperChatOperation).toHaveBeenCalledTimes(2)
    oldResolve({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'old' } })
    await old
    expect(keeperSending.value.echo).toBe(true)
    await hydrateTrackedKeeperChatOperations('echo')
    expect(fetchKeeperChatOperation).toHaveBeenCalledTimes(2)
    currentResolve({ operationId: 'restored-op', state: { kind: 'cancelled', completedAt: 3 } })
    await current
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.delivery).toBe('cancelled')
    expect(keeperSending.value.echo).toBe(false)
    clearStoredToken()
  })

  it('does not poll with new credentials on behalf of an old recovery after queued sleep', async () => {
    vi.useFakeTimers()
    try {
      storeDraft()
      setStoredToken('fixture-old')
      fetchKeeperChatOperation.mockResolvedValueOnce({ operationId: 'restored-op', state: { kind: 'queued' } })
        .mockResolvedValueOnce({ operationId: 'restored-op', state: { kind: 'cancelled', completedAt: 3 } })
      const recovery = hydrateTrackedKeeperChatOperations('echo')
      await Promise.resolve()
      setStoredToken('fixture-new')
      await vi.runAllTimersAsync()
      await recovery
      expect(fetchKeeperChatOperation).toHaveBeenCalledTimes(1)
      expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.delivery).toBe('streaming')
      await hydrateTrackedKeeperChatOperations('echo')
      expect(fetchKeeperChatOperation).toHaveBeenCalledTimes(2)
      expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.delivery).toBe('cancelled')
    } finally {
      clearStoredToken()
      vi.useRealTimers()
    }
  })

  it.each(['resolve', 'reject'] as const)('retains recovery when credentials change between history admission and caller settlement (%s)', async outcome => {
    storeDraft()
    setStoredToken('fixture-old')
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'result' } })
    let resolve!: (rows: unknown[]) => void
    let reject!: (error: Error) => void
    fetchKeeperChatHistory.mockReturnValueOnce(new Promise((yes, no) => { resolve = yes; reject = no }))
    const recovery = hydrateTrackedKeeperChatOperations('echo')
    await vi.waitFor(() => expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1))
    if (outcome === 'reject') reject(new Error('old scope history failed'))
    else resolve([
      { id: 'canonical-user', role: 'user', content: 'input', ts: 1,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'accepted_user'), delivery_provenance_status: 'valid' },
      { id: 'canonical-assistant', role: 'assistant', content: 'answer', ts: 2,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'terminal_result'), delivery_provenance_status: 'valid' },
    ])
    queueMicrotask(() => {
      setStoredToken('fixture-new')
      keeperChatHistoryErrors.value = { echo: 'current scope history error' }
    })
    await recovery
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    expect(keeperChatHistoryErrors.value.echo).toBe('current scope history error')
    clearStoredToken()
  })

  it.each(['resolve', 'reject'] as const)('retains operation recovery when history authentication changes (%s)', async outcome => {
    storeDraft()
    setStoredToken('fixture-old')
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'result' } })
    let resolve!: (rows: unknown[]) => void
    let reject!: (error: Error) => void
    fetchKeeperChatHistory.mockReturnValueOnce(new Promise((yes, no) => { resolve = yes; reject = no }))
    const recovery = hydrateTrackedKeeperChatOperations('echo')
    await vi.waitFor(() => expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1))
    setStoredToken('fixture-new')
    keeperChatHistoryErrors.value = { echo: 'current scope error' }
    if (outcome === 'reject') reject(new Error('old scope failure'))
    else resolve([
      { id: 'old-user', role: 'user', content: 'input', ts: 1,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'accepted_user'), delivery_provenance_status: 'valid' },
      { id: 'old-assistant', role: 'assistant', content: 'old scope answer', ts: 2,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'terminal_result'), delivery_provenance_status: 'valid' },
    ])
    await recovery
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'old-assistant')).toBe(false)
    expect(trackedKeeperChatOperationsForKeeper('echo')).toHaveLength(1)
    expect(keeperChatHistoryErrors.value.echo).toBe('current scope error')
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'current-user', role: 'user', content: 'input', ts: 1,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'accepted_user'), delivery_provenance_status: 'valid' },
      { id: 'current-assistant', role: 'assistant', content: 'current scope answer', ts: 2,
        delivery_provenance: operationDeliveryProvenance('restored-op', 'terminal_result'), delivery_provenance_status: 'valid' },
    ])
    await hydrateTrackedKeeperChatOperations('echo')
    expect(trackedKeeperChatOperationsForKeeper('echo')).toEqual([])
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'current-assistant')).toBe(true)
    clearStoredToken()
  })

  it.each([false, true])('restores durable quarantine into canonical history (continuation=%s)', async continuation => {
    const provenance = toolCallDeliveryProvenance(operationDeliveryProvenance('restored-op', 'terminal_result'), 'execution', 0)
    const storedTool = { toolOwnerKey: operationDeliveryProvenance('restored-op', 'terminal_result').delivery_key, id: 'stored-tool', label: 'Read', text: '', rawText: 'stored args', delivery: 'error' as const,
      executionId: 'execution', deliveryProvenance: continuation ? null : provenance, toolCallId: 'provider', toolCallEnded: true,
      toolOccurrence: { kind: 'identified' as const, streamScope: 1, blockIndex: 0 }, toolOccurrenceQuarantined: true as const }
    upsertTrackedKeeperChatOperation({ operationId: 'restored-op', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'authored', rawText: 'authored', delivery: 'streaming', streamState: 'streaming',
        toolObservations: { kind: 'known', entries: [storedTool] },
        traceSteps: [{ kind: 'tool', name: 'Read', toolOccurrenceId: 'stored-tool', executionId: 'execution', status: 'err' }] } })
    keeperThreads.value = { echo: [{ ...storedTool, id: 'canonical-tool', role: 'tool', source: 'tool_result',
      toolOwnerKey: undefined, deliveryProvenance: continuation ? toolCallDeliveryProvenance({ delivery_key: { kind: 'operation_native', operation_id: 'restored-op', continuation_id: 'native' }, transcript_slot: { kind: 'terminal_result' } }, 'execution', 0) : provenance,
      toolOccurrence: undefined, toolOccurrenceQuarantined: undefined, toolCallId: undefined,
      delivery: 'history', rawText: 'canonical args' }] }
    fetchKeeperChatOperation.mockRejectedValue(new Error('lookup unavailable'))
    await hydrateTrackedKeeperChatOperations('echo')
    expect(requiredFixture(keeperThreads.value.echo).filter(entry => entry.role === 'tool')).toMatchObject([
      { id: 'canonical-tool', rawText: 'canonical args', toolCallId: 'provider', toolCallEnded: true,
        toolOccurrenceQuarantined: true, toolOccurrence: { kind: 'identified', streamScope: 1, blockIndex: 0 } },
    ])
    expect(requiredFixture(keeperThreads.value.echo).find(entry => entry.role === 'assistant')).toMatchObject({
      rawText: 'authored', traceSteps: [{ toolOccurrenceId: 'canonical-tool' }],
    })
    expect(requiredFixture(keeperThreads.value.echo).find(entry => entry.role === 'assistant')?.toolObservationAuthority).toBeUndefined()
  })

  it.each([
    { kind: 'succeeded', completedAt: 2, outcomeRef: 'outcome' },
    { kind: 'cancelled', completedAt: 2 },
    { kind: 'failed', completedAt: 2, failureKind: 'Interrupted_by_restart', detail: 'restart', outcomeRef: null },
  ] as const)('settles $kind while retaining observed content and original occurrence time', async state => {
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state })
    await hydrateTrackedKeeperChatOperations('echo')
    const entry = requiredFixture(keeperThreads.value.echo).find(candidate => candidate.role === 'assistant')
    expect(entry).toMatchObject({ rawText: 'partial authored answer', text: 'partial authored answer',
      timestamp: '2026-10-11T00:00:00Z', traceSteps: [{ kind: 'think', text: 'exposed reasoning' }],
      streamState: null, responseState: { phase: 'terminal' } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft).toMatchObject({
      rawText: 'partial authored answer', responseState: { phase: 'terminal' },
    })
    keeperThreads.value = {}
    await hydrateTrackedKeeperChatOperations('echo')
    expect(requiredFixture(keeperThreads.value.echo).find(candidate => candidate.role === 'assistant')?.rawText).toBe('partial authored answer')
  })

  it('retains observed content and tracking when operation lookup temporarily fails', async () => {
    storeDraft()
    fetchKeeperChatOperation.mockRejectedValue(new Error('temporary network failure'))
    await hydrateTrackedKeeperChatOperations('echo')
    expect(requiredFixture(keeperThreads.value.echo).find(candidate => candidate.role === 'assistant')).toMatchObject({
      rawText: 'partial authored answer', timestamp: '2026-10-11T00:00:00Z', delivery: 'error',
    })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).operationId).toBe('restored-op')
  })
  it('releases the stored observation only after the canonical operation turn replaces it', async () => {
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'result' } })
    fetchKeeperChatHistory.mockResolvedValue([
      { id: 'canonical-user', role: 'user', content: 'input', ts: 1,
        delivery_provenance: { delivery_key: { kind: 'operation', operation_id: 'restored-op' }, transcript_slot: { kind: 'accepted_user' } },
        delivery_provenance_status: 'valid' },
      { id: 'canonical-assistant', role: 'assistant', content: 'complete answer', ts: 2,
        delivery_provenance: { delivery_key: { kind: 'operation', operation_id: 'restored-op' }, transcript_slot: { kind: 'terminal_result' } },
        delivery_provenance_status: 'valid' },
    ])
    await hydrateTrackedKeeperChatOperations('echo')
    expect(trackedKeeperChatOperationsForKeeper('echo')).toEqual([])
    expect(requiredFixture(keeperThreads.value.echo).filter(entry => entry.role === 'assistant')).toMatchObject([
      { id: 'canonical-assistant', text: 'complete answer', traceSteps: [{ kind: 'think', text: 'exposed reasoning' }] },
    ])
  })

  it.each([
    [{ kind: 'succeeded', completedAt: 2, outcomeRef: 'result' }, 'delivered'],
    [{ kind: 'cancelled', completedAt: 2 }, 'cancelled'],
  ] as const)('retains the $1 receipt when canonical history is unavailable', async (state, delivery) => {
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state })
    fetchKeeperChatHistory.mockRejectedValue(new Error('history transport unavailable'))
    await hydrateTrackedKeeperChatOperations('echo')
    expect(requiredFixture(keeperThreads.value.echo).find(entry => entry.role === 'assistant')).toMatchObject({
      delivery, rawText: 'partial authored answer', responseState: { phase: 'terminal' },
    })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.delivery).toBe(delivery)
    expect(keeperChatHistoryErrors.value.echo).toContain('history transport unavailable')
  })

  it.each([
    new Error('temporary operation transport failure'),
    Object.assign(new Error('missing operation'), { method: 'GET', status: 404, path: '/api/v1/keepers/echo/chat/operations/restored-op' }),
    new KeeperChatOperationMissingError('echo', 'restored-op',
      new ApiRequestError({ method: 'GET', path: '/lookup', status: 404, detail: 'explicit missing operation' })),
  ])('preserves the retained terminal receipt when a later lookup fails', async failure => {
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: { kind: 'succeeded', completedAt: 2, outcomeRef: 'result' } })
    await hydrateTrackedKeeperChatOperations('echo')
    keeperThreads.value = {}
    fetchKeeperChatOperation.mockRejectedValue(failure)
    await hydrateTrackedKeeperChatOperations('echo')
    const entry = requiredFixture(keeperThreads.value.echo).find(candidate => candidate.role === 'assistant')
    expect(entry).toMatchObject({ delivery: 'delivered', rawText: 'partial authored answer', responseState: { phase: 'terminal' } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.delivery).toBe('delivered')
    expect(keeperActionErrors.value.echo).toBe(failure.message)
  })

})
