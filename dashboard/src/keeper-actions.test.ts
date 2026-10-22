import { operationDeliveryProvenance } from './keeper-delivery-provenance'
import { toolCallDeliveryProvenance } from './test-support/tool-delivery-provenance'
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
  fetchKeeperChatHistoryPage,
  streamKeeperMessage,
} = vi.hoisted(() => ({
  cancelKeeperChatOperation: vi.fn(),
  fetchKeeperChatOperation: vi.fn(),
  fetchKeeperChatHistory: vi.fn(),
  fetchKeeperChatHistoryPage: vi.fn(),
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
  fetchKeeperChatHistoryPage,
  streamKeeperMessage,
}))
vi.mock('./api/dashboard', () => ({ fetchKeeperToolCalls }))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard, shellAuthSummary }))

import {
  _resetActiveKeeperStreamsForTests,
  _resetLiveSendRequestOwnersForTests,
  activeKeeperName,
  keeperActionErrors,
  keeperChatHistoryErrors,
  keeperChatHistoryHydration,
  keeperChatHistoryPages,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperStatusDetails,
  keeperStreamLastEventAt,
  keeperThreads,
  liveSendOwnsRequest,
  appendThreadEntry,
  THREAD_ENTRY_CAP,
} from './keeper-state'
import {
  _resetCancelledKeeperThreadRequestsForTests,
  _resetKeeperThreadMessageSendGuardsForTests,
  _resetChatHydrationForTests,
  cancelActiveKeeperThreadMessage,
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
import { ApiRequestError, clearStoredToken, setStoredToken } from './api/core'
import {
  lookupToolCallOutput,
  resetToolCallOutputs,
  toolCallOutputHydrationContract,
  toolCallOutputHydrationFailureReason,
  toolCallOutputHydrationStatus,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from './tool-call-output-store'
import { _resetKeeperStreamBuffersForTests, applyKeeperOperationTurnEvent } from './keeper-stream'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperChatHistoryMessage } from './api/keeper'
import type { ToolCallEntry } from './api/dashboard'
import type { KeeperStatusDetail } from './types'

beforeEach(() => {
  fetchKeeperChatHistoryPage.mockReset().mockResolvedValue({ messages: [], nextCursor: null, hasMore: false })
  clearStoredToken()
  shellAuthSummary.value = { effective_role: 'admin' }
  fetchKeeperToolCalls.mockReset()
  fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
  resetToolCallOutputs()
  _resetKeeperStreamBuffersForTests()
})

describe('progressive first conversation read', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperHydrating.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
  })
  function deferred<T>() {
    let resolve!: (value: T) => void
    let reject!: (error: Error) => void
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
    return { promise, resolve, reject }
  }
  const row = (id: string, content = id): KeeperChatHistoryMessage => ({ id, role: 'user', content, ts: 1, delivery_provenance: null, delivery_provenance_status: 'absent' })
  const page = (messages: KeeperChatHistoryMessage[]) => ({ messages, nextCursor: 'older', hasMore: true })

  it('publishes direct rows before enrichment, preserving local rows and the older cursor', async () => {
    const aggregate = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistory.mockReturnValue(aggregate.promise)
    fetchKeeperChatHistoryPage.mockResolvedValue(page([row('recent')]))
    appendThreadEntry('echo', { id: 'local', role: 'user', source: 'direct_user', label: '나', text: 'queued', timestamp: new Date(2000).toISOString(), delivery: 'queued' })
    appendThreadEntry('echo', { id: 'recent', role: 'user', source: 'direct_user', label: '나', text: 'observed', delivery: 'history',
      streamContract: { source: 'sse_event', status: 'backend_terminal_event', eventName: 'done' } })
    appendThreadEntry('echo', { id: 'autonomous', role: 'assistant', source: 'autonomous_turn', label: 'echo', text: 'prior context', delivery: 'history' })
    const older = { id: 'older', role: 'user' as const, source: 'direct_user' as const, label: '나', text: 'older page', delivery: 'history' as const }
    keeperChatHistoryPages.value = { echo: { entries: [older], nextCursor: 'walk-in-progress', hasMore: true } }
    const pending = hydrateKeeperChatHistory('echo')
    await vi.waitFor(() => expect(keeperChatHistoryHydration.value.echo).toBe('partial'))
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(expect.arrayContaining(['recent', 'local', 'autonomous', 'older']))
    expect(keeperThreads.value.echo?.find(entry => entry.id === 'recent')?.streamContract).toMatchObject({ source: 'sse_event', eventName: 'done' })
    expect(keeperChatHistoryPages.value.echo?.nextCursor).toBe('walk-in-progress')
    expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(1)
    aggregate.resolve([row('recent', 'enriched')])
    await pending
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperThreads.value.echo?.filter(entry => entry.id === 'recent')).toHaveLength(1)
    expect(keeperThreads.value.echo?.find(entry => entry.id === 'recent')?.text).toBe('enriched')
    expect(keeperThreads.value.echo?.find(entry => entry.id === 'recent')?.streamContract).toMatchObject({ source: 'sse_event', eventName: 'done' })
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'older')).toBe(true)
    expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(1)
  })

  it('keeps independently observed direct appends missing from the aggregate snapshot', async () => {
    const aggregate = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistory.mockReturnValue(aggregate.promise)
    fetchKeeperChatHistoryPage.mockResolvedValue(page([row('newly-appended')]))
    const pending = hydrateKeeperChatHistory('echo')
    await vi.waitFor(() => expect(keeperChatHistoryHydration.value.echo).toBe('partial'))
    aggregate.resolve([row('older')])
    await pending
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(expect.arrayContaining(['older', 'newly-appended']))
  })

  it('bounds different page/role windows and replaces their union on a forced refresh', async () => {
    const aggregate = deferred<KeeperChatHistoryMessage[]>()
    const physical = Array.from({ length: 240 }, (_, index) => ({ ...row(`direct-${index}`), ts: 1000 + index }))
    const roleWindow = physical.slice(-100)
    fetchKeeperChatHistory.mockReturnValueOnce(aggregate.promise).mockResolvedValueOnce(roleWindow)
    fetchKeeperChatHistoryPage.mockResolvedValueOnce(page(physical))
    const pending = hydrateKeeperChatHistory('echo')
    await vi.waitFor(() => expect(keeperChatHistoryHydration.value.echo).toBe('partial'))
    aggregate.resolve(roleWindow)
    await pending
    expect(keeperThreads.value.echo).toHaveLength(THREAD_ENTRY_CAP)
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toContain('direct-40')
    expect(keeperChatHistoryPages.value.echo).toBeUndefined()
    await hydrateKeeperChatHistory('echo', { force: true })
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(roleWindow.map(message => message.id))
  })

  it('retains preview rows on aggregate failure and permits an ordinary retry', async () => {
    const aggregate = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistory.mockReturnValueOnce(aggregate.promise)
    fetchKeeperChatHistoryPage.mockResolvedValue(page([row('recent')]))
    const pending = hydrateKeeperChatHistory('echo')
    await vi.waitFor(() => expect(keeperChatHistoryHydration.value.echo).toBe('partial'))
    aggregate.reject(new Error('aggregate unavailable'))
    await pending
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'recent')).toBe(true)
    expect(keeperChatHistoryHydration.value.echo).toBe('failed')
    expect(keeperChatHistoryErrors.value.echo).toContain('aggregate unavailable')
    fetchKeeperChatHistory.mockResolvedValueOnce([row('recent')])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
  })

  it('ignores a preview that completes after aggregate failure', async () => {
    const preview = deferred<ReturnType<typeof page>>()
    fetchKeeperChatHistoryPage.mockReturnValueOnce(preview.promise)
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('aggregate unavailable'))
    await hydrateKeeperChatHistory('echo')
    preview.resolve(page([row('late')]))
    await preview.promise
    expect(keeperChatHistoryHydration.value.echo).toBe('failed')
    expect(keeperChatHistoryErrors.value.echo).toContain('aggregate unavailable')
    expect(keeperThreads.value.echo).toBeUndefined()
  })

  it('does not infer empty conversation from an empty direct page', async () => {
    const aggregate = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistory.mockReturnValue(aggregate.promise)
    const pending = hydrateKeeperChatHistory('echo')
    await Promise.resolve()
    expect(keeperChatHistoryHydration.value.echo).toBeUndefined()
    aggregate.resolve([{ ...row('autonomous'), role: 'assistant' }])
    await pending
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'autonomous')).toBe(true)
  })

  it('accepts aggregate history when the optional page fails', async () => {
    fetchKeeperChatHistoryPage.mockRejectedValue(new Error('page unavailable'))
    fetchKeeperChatHistory.mockResolvedValue([row('aggregate')])
    await hydrateKeeperChatHistory('echo')
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
  })

  it('ignores obsolete page and aggregate completions after a forced refresh', async () => {
    const oldPage = deferred<ReturnType<typeof page>>()
    const oldAggregate = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistoryPage.mockReturnValueOnce(oldPage.promise).mockResolvedValueOnce(page([row('new')]))
    fetchKeeperChatHistory.mockReturnValueOnce(oldAggregate.promise).mockResolvedValueOnce([row('new')])
    const obsolete = hydrateKeeperChatHistory('echo')
    await hydrateKeeperChatHistory('echo', { force: true })
    oldPage.resolve(page([row('stale-page')]))
    oldAggregate.resolve([row('stale-aggregate')])
    await obsolete
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['new'])
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
  })
})


function requiredFixture<T>(value: T | undefined): T {
  if (value === undefined) throw new Error('Expected fixture state to exist')
  return value
}

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

  it('retains inactive history eligibility after a failed forced refresh', async () => {
    activeKeeperName.value = 'other'
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'original', role: 'assistant', content: 'original answer', ts: 1 },
    ])
    await hydrateKeeperChatHistory('echo')
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('temporary refresh failure'))
    await hydrateKeeperChatHistory('echo', { force: true })
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'latest', role: 'assistant', content: 'latest answer', ts: 2 },
    ])
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(3)
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'latest')).toBe(true)
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

  it('debounces a burst of appends into one forced refetch', async () => {
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

  it('keeps backend stream contracts when hydrating server history', async () => {
    appendThreadEntry('echo', {
      id: 'msg-contract-assistant', role: 'assistant', source: 'direct_assistant',
      label: 'echo', text: 'observed', delivery: 'history',
      streamContract: { source: 'sse_event', status: 'backend_terminal_event', eventName: 'done' },
    })
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
    refreshActiveKeeperChatHistory()
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
  })

  it('fetches the open keeper transcript again on reconnect even when it is already loaded', async () => {
    activeKeeperName.value = 'echo'
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    await refreshKnownKeeperChatHistories()

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })

  it('names the Keepers whose history could not be fetched after a reconnect', async () => {
    await hydrateKeeperChatHistory('fine')
    await hydrateKeeperChatHistory('broken')
    fetchKeeperChatHistory.mockReset().mockImplementation(name => name === 'broken'
      ? Promise.reject(new Error('history unavailable')) : Promise.resolve([]))
    await expect(refreshKnownKeeperChatHistories()).rejects.toThrow('Known Keeper history refresh incomplete: broken')
    expect(fetchKeeperChatHistory).toHaveBeenCalledWith('fine')
  })

  it('recovers a missed completed turn for an inactive previously visited Keeper', async () => {
    await hydrateKeeperChatHistory('inactive')
    await hydrateKeeperChatHistory('active')
    activeKeeperName.value = 'active'
    fetchKeeperChatHistory.mockReset().mockImplementation(name => Promise.resolve(name === 'inactive'
      ? [{ id: 'missed-turn', role: 'assistant', content: 'missed answer', ts: 1 }] : []))
    await refreshKnownKeeperChatHistories()
    expect(fetchKeeperChatHistory).toHaveBeenCalledWith('active')
    expect(fetchKeeperChatHistory).toHaveBeenCalledWith('inactive')
    expect(keeperThreads.value.inactive?.[0]?.text).toBe('missed answer')
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

  it('leaves an already loaded transcript alone on a route or periodic refresh', async () => {
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

  it.each(['waiting_for_input', 'continuation_checkpoint'] as const)(
    'hands off %s to the same tracked operation and accepts its actual later answer', async (turnOutcome) => {
      let operationId = ''
      let resolveLookup!: (operation: {operationId: string; state: {
        kind: 'succeeded'; completedAt: number; outcomeRef: string;
      }}) => void
      const lookup = new Promise<{operationId: string; state: {
        kind: 'succeeded'; completedAt: number; outcomeRef: string;
      }}>(resolve => { resolveLookup = resolve })
      fetchKeeperChatOperation.mockReturnValue(lookup)
      fetchKeeperChatHistory.mockResolvedValue([])
      streamKeeperMessage.mockImplementation(async (_name: string, _message: string, opts: {
        operationId: string; onEvent: (event: KeeperChatStreamEvent) => void;
      }) => {
        operationId = opts.operationId
        opts.onEvent({type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
          value: {operation_id: operationId, state: 'Running', queued_count: 0}})
        opts.onEvent({type: 'RUN_STARTED'})
        opts.onEvent({type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS', value: {
          reply: 'Which original branch?', turn_outcome: turnOutcome, turn_ref: 'original#1',
        }})
        if (turnOutcome === 'continuation_checkpoint') opts.onEvent({type: 'CUSTOM',
          name: 'KEEPER_CONTINUATION_CHECKPOINT', value: {message: '', request_id: operationId}})
        opts.onEvent({type: 'RUN_FINISHED'})
        return {terminal: true}
      })
      await sendKeeperThreadMessage('echo', 'original request')
      expect(trackedKeeperChatOperationsForKeeper('echo').map(request => request.operationId)).toEqual([operationId])
      expect(keeperThreads.value.echo?.find(entry => entry.role === 'assistant')).toMatchObject({
        delivery: 'queued', details: {turnOutcome}, responseState: {phase: 'awaiting-continuation'},
      })
      expect(fetchKeeperChatOperation).toHaveBeenCalled()
      applyKeeperOperationTurnEvent('echo', {operationId, event: {type: 'RUN_STARTED'}})
      applyKeeperOperationTurnEvent('echo', {operationId, event: {type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
        value: {reply: 'actual later answer', turn_outcome: 'visible_reply', turn_ref: 'original#2'}}})
      applyKeeperOperationTurnEvent('echo', {operationId, event: {type: 'RUN_FINISHED'}})
      expect(keeperThreads.value.echo?.find(entry => entry.role === 'assistant')).toMatchObject({
        text: 'actual later answer', delivery: 'delivered', responseState: {phase: 'terminal'},
      })
      fetchKeeperChatHistory.mockResolvedValue([
        {id: 'canonical-user', role: 'user', content: 'original request', ts: 1,
          delivery_provenance: operationDeliveryProvenance(operationId, 'accepted_user'),
          delivery_provenance_status: 'valid'},
        {id: 'canonical-answer', role: 'assistant', content: 'actual later answer', ts: 2,
          delivery_provenance: operationDeliveryProvenance(operationId, 'terminal_result'),
          delivery_provenance_status: 'valid'},
      ])
      resolveLookup({operationId, state: {kind: 'succeeded', completedAt: 2, outcomeRef: 'actual-result'}})
      await vi.waitFor(() => expect(trackedKeeperChatOperationsForKeeper('echo')).toEqual([]))
    },
  )

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

  it('admits a post-terminal broadcast tool event instead of losing it to live-send ownership', async () => {
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
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'answer' })
      opts.onEvent({ type: 'RUN_FINISHED' })
      // The server broadcasts every operation event before publishing it to
      // the direct sink, so a post-terminal tool frame can land on the
      // observer connection while the send tail has not reached
      // clearActiveStream yet. It must not be discarded by live-send
      // ownership: the canceled direct reader will never carry it.
      applyKeeperOperationTurnEvent('echo', {
        operationId: opts.operationId,
        event: {
          type: 'TOOL_CALL_START',
          toolStreamScope: 0,
          toolCallBlockIndex: 4,
          toolCallName: 'Read',
          toolCallId: 'late-tool',
        },
      })
      return { terminal: true }
    })

    await sendKeeperThreadMessage('echo', '질문')

    expect(keeperThreads.value.echo?.find(entry => entry.toolCallId === 'late-tool')).toMatchObject({
      role: 'tool',
      label: 'Read',
      delivery: 'streaming',
    })
    expect(keeperThreads.value.echo?.filter(entry => entry.role === 'assistant').at(-1)).toMatchObject({
      text: 'answer',
      delivery: 'delivered',
    })
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

  it('does not end an accepted operation as delivered when the stream dropped a frame', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        operationId: string
        onEvent: (event: KeeperChatStreamEvent) => void
        onDecodeError: (reason: string) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: opts.operationId, state: 'Running', queued_count: 0 },
      })
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'a' })
      opts.onDecodeError('A Keeper stream frame does not match the protocol.')
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'c' })
      opts.onEvent({ type: 'RUN_FINISHED' })
      return { terminal: true }
    })
    // The server finished the operation, but the stored transcript cannot be
    // read, so the incomplete local copy is all the panel has.
    fetchKeeperChatOperation.mockResolvedValue({
      operationId: 'terminal',
      state: { kind: 'succeeded', completedAt: 1 },
    })
    fetchKeeperChatHistory.mockRejectedValue(new Error('history unavailable'))

    await sendKeeperThreadMessage('echo', 'hi')

    expect(fetchKeeperChatOperation).toHaveBeenCalled()
    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply).toMatchObject({
      text: 'a',
      delivery: 'error',
      error: 'A Keeper stream frame does not match the protocol.',
    })
    expect(keeperActionErrors.value.echo).toBe('A Keeper stream frame does not match the protocol.')
  })

  it('marks a stream that dropped a frame before acceptance as incomplete with the reason', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        onEvent: (event: KeeperChatStreamEvent) => void
        onDecodeError: (reason: string) => void
      },
    ) => {
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'a' })
      opts.onDecodeError('A Keeper stream frame could not be decoded.')
      opts.onEvent({ type: 'RUN_FINISHED' })
      return { terminal: true }
    })

    await sendKeeperThreadMessage('echo', 'hi')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply).toMatchObject({
      text: 'a',
      delivery: 'interrupted',
      error: 'A Keeper stream frame could not be decoded.',
    })
    expect(keeperActionErrors.value.echo).toBe('A Keeper stream frame could not be decoded.')
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
      include_repository_checkouts: true,
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
    _resetChatHydrationForTests()
    keeperThreads.value = {}
    keeperHydrating.value = {}
    fetchKeeperChatHistoryPage.mockReset()
  })

  const row = (id: string, ts: number) => ({ id, role: 'user', content: id, ts })

  it('uses each server cursor and retains earlier rows through refresh and live append', async () => {
    fetchKeeperChatHistoryPage
      .mockResolvedValueOnce({
        messages: Array.from({ length: THREAD_ENTRY_CAP + 1 }, (_, i) => row(`new-${i}`, 1000 + i)),
        hasMore: true,
        nextCursor: 'position-1000',
      })
      .mockResolvedValueOnce({ messages: [row('old', 500)], hasMore: false, nextCursor: null })

    await loadFullKeeperHistory(' echo ')
    await loadFullKeeperHistory('echo')
    await loadFullKeeperHistory('echo')

    expect(fetchKeeperChatHistoryPage.mock.calls).toEqual([['echo', undefined], ['echo', 'position-1000']])
    expect(keeperThreads.value.echo?.[0]?.id).toBe('old')
    expect(keeperThreads.value.echo).toHaveLength(THREAD_ENTRY_CAP + 2)
    fetchKeeperChatHistory.mockResolvedValueOnce([row('new-200', 1200)])
    await hydrateKeeperChatHistory('echo', { force: true })
    appendThreadEntry('echo', { id: 'live', role: 'user', source: 'direct_user', label: '나', text: 'live', delivery: 'sending' })
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toContain('old')
    expect(keeperThreads.value.echo?.filter(entry => entry.id === 'new-200')).toHaveLength(1)
    expect(keeperChatHistoryPages.value.echo?.hasMore).toBe(false)
  })

  it('accepts canonical page content while preserving exact existing stream observations', async () => {
    const streamContract = { source: 'sse_event' as const, status: 'backend_terminal_event' as const, eventName: 'RUN_FINISHED' }
    keeperThreads.value = { echo: [{
      id: 'server-row', role: 'assistant', source: 'direct_assistant', label: 'echo',
      text: 'stale content', delivery: 'history', streamContract,
    }] }
    fetchKeeperChatHistoryPage.mockResolvedValueOnce({
      messages: [{ id: 'server-row', role: 'assistant', content: 'canonical content', ts: 500 }],
      hasMore: false, nextCursor: null,
    })
    await loadFullKeeperHistory('echo')
    expect(keeperThreads.value.echo).toHaveLength(1)
    expect(keeperThreads.value.echo?.[0]?.text).toBe('canonical content')
    expect(keeperThreads.value.echo?.[0]?.streamContract).toEqual(streamContract)
  })

  it('keeps the cursor retryable after malformed-page rejection without losing loaded rows', async () => {
    fetchKeeperChatHistoryPage
      .mockResolvedValueOnce({ messages: [row('new', 1000)], hasMore: true, nextCursor: 'position-1000' })
      .mockRejectedValueOnce(new Error('fetchKeeperChatHistoryPage: invalid history page row'))
      .mockResolvedValueOnce({ messages: [row('old', 500)], hasMore: false, nextCursor: null })
    await loadFullKeeperHistory('echo')
    await loadFullKeeperHistory('echo')
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['new'])
    expect(keeperChatHistoryErrors.value.echo).toBe('fetchKeeperChatHistoryPage: invalid history page row')
    expect(keeperChatHistoryPages.value.echo?.nextCursor).toBe('position-1000')
    expect(keeperHydrating.value.echo).toBe(false)
    await loadFullKeeperHistory('echo')
    expect(fetchKeeperChatHistoryPage.mock.calls.at(-1)).toEqual(['echo', 'position-1000'])
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
  })

  it('retires a replaced-file cursor, reloads the transcript, and starts the next walk anew', async () => {
    fetchKeeperChatHistoryPage
      .mockResolvedValueOnce({ messages: [row('old-file-row', 100)], hasMore: true, nextCursor: 'old-file-position' })
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/chat/history/page', status: 409, detail: 'Conversation changed' }))
      .mockResolvedValueOnce({ messages: [row('new-file-row', 200)], hasMore: false, nextCursor: null })
    fetchKeeperChatHistory.mockResolvedValueOnce([row('new-file-row', 200)])
    await loadFullKeeperHistory('echo')
    await loadFullKeeperHistory('echo')
    expect(keeperChatHistoryPages.value.echo).toBeUndefined()
    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['new-file-row'])
    expect(keeperChatHistoryErrors.value.echo).toContain('Conversation changed')
    await loadFullKeeperHistory('echo')
    expect(fetchKeeperChatHistoryPage.mock.calls).toEqual([
      ['echo', undefined], ['echo', 'old-file-position'], ['echo'], ['echo', undefined],
    ])
  })

  it('retires old-file rows when the replacement tail and next page are empty while keeping independent live state', async () => {
    fetchKeeperChatHistoryPage
      .mockResolvedValueOnce({
        messages: [row('old-file-row', 100), { id: 'old-file-failure', role: 'request_failure', content: 'failed request', ts: 101 }],
        hasMore: true, nextCursor: 'old-file-position',
      })
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/chat/history/page', status: 409, detail: 'Conversation changed' }))
      .mockResolvedValueOnce({ messages: [], hasMore: false, nextCursor: null })
    fetchKeeperChatHistory.mockResolvedValueOnce([])
    await loadFullKeeperHistory('echo')
    appendThreadEntry('echo', { id: 'queued-local', role: 'user', source: 'direct_user', label: '나', text: 'queued input', delivery: 'queued' })
    appendThreadEntry('echo', { id: 'streaming-local', role: 'assistant', source: 'direct_assistant', label: 'echo', text: 'live output', delivery: 'streaming' })
    appendThreadEntry('echo', { id: 'autonomous-record', role: 'assistant', source: 'autonomous_turn', label: 'echo', text: 'independent checkpoint', delivery: 'history' })

    await loadFullKeeperHistory('echo')

    expect(keeperChatHistoryPages.value.echo).toBeUndefined()
    expect(keeperThreads.value.echo?.map(entry => entry.id).sort()).toEqual(['autonomous-record', 'queued-local', 'streaming-local'])
    expect(keeperChatHistoryErrors.value.echo).toContain('Conversation changed')
    await loadFullKeeperHistory('echo')
    expect(keeperThreads.value.echo?.map(entry => entry.id).sort()).toEqual(['autonomous-record', 'queued-local', 'streaming-local'])
    expect(keeperThreads.value.echo?.find(entry => entry.id === 'queued-local')?.delivery).toBe('queued')
    expect(keeperThreads.value.echo?.find(entry => entry.id === 'streaming-local')?.delivery).toBe('streaming')
    expect(fetchKeeperChatHistoryPage.mock.calls.at(-1)).toEqual(['echo', undefined])
  })

  it('keeps independent in-flight rows exactly once when a nonempty older page arrives', async () => {
    appendThreadEntry('echo', { id: 'queued-local', role: 'user', source: 'direct_user', label: '나', text: 'queued input', delivery: 'queued' })
    appendThreadEntry('echo', { id: 'streaming-local', role: 'assistant', source: 'direct_assistant', label: 'echo', text: 'live output', delivery: 'streaming' })
    fetchKeeperChatHistoryPage.mockResolvedValueOnce({ messages: [row('older-canonical', 100)], hasMore: false, nextCursor: null })

    await loadFullKeeperHistory('echo')

    expect(keeperThreads.value.echo?.map(entry => entry.id)).toEqual(['older-canonical', 'queued-local', 'streaming-local'])
    expect(keeperThreads.value.echo?.map(entry => entry.delivery)).toEqual(['history', 'queued', 'streaming'])
  })

  it('ignores an empty name and shares one pending request per keeper', async () => {
    let resolve!: (value: unknown) => void
    fetchKeeperChatHistoryPage.mockReturnValueOnce(new Promise(done => { resolve = done }))
    await loadFullKeeperHistory(' ')
    const loading = loadFullKeeperHistory('echo')
    await loadFullKeeperHistory('echo')
    expect(fetchKeeperChatHistoryPage).toHaveBeenCalledTimes(1)
    resolve({ messages: [], hasMore: false, nextCursor: null })
    await loading
    expect(keeperHydrating.value.echo).toBe(false)
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

  function deferred<T>() {
    let resolve!: (value: T) => void
    let reject!: (reason: Error) => void
    const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
    return { promise, resolve, reject }
  }

  function historyMessage(id: string, content = id, ts = 1): KeeperChatHistoryMessage {
    return { id, role: 'user', content, ts,
      delivery_provenance: null, delivery_provenance_status: 'absent' }
  }

  it('retries first hydration after its replacement operation-history read fails', async () => {
    const original = deferred<KeeperChatHistoryMessage[]>()
    const replacement = deferred<KeeperChatHistoryMessage[]>()
    const replacementStarted = deferred<void>()
    fetchKeeperChatHistory.mockReturnValueOnce(original.promise).mockImplementationOnce(() => {
      replacementStarted.resolve(undefined)
      return replacement.promise
    })
    const initialHydration = hydrateKeeperChatHistory('echo')
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: {
      kind: 'succeeded', completedAt: 2, outcomeRef: 'result',
    } })
    const reconciliation = hydrateTrackedKeeperChatOperations('echo')
    await replacementStarted.promise
    replacement.reject(new Error('replacement history unavailable'))
    await reconciliation
    original.resolve([historyMessage('stale-original', 'stale')])
    await initialHydration

    expect(keeperChatHistoryHydration.value.echo).toBe('failed')
    expect(keeperChatHistoryErrors.value.echo).toContain('replacement history unavailable')
    expect(keeperHydrating.value.echo).toBe(false)
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'stale-original')).toBe(false)
    expect(fetchKeeperToolCalls).not.toHaveBeenCalled()
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.delivery).toBe('delivered')

    fetchKeeperChatHistory.mockResolvedValueOnce([historyMessage('retry-history', 'retry', 3)])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(3)
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'retry-history')).toBe(true)
  })

  async function startReplacement(force = false) {
    const original = deferred<KeeperChatHistoryMessage[]>()
    const replacement = deferred<KeeperChatHistoryMessage[]>()
    const replacementStarted = deferred<void>()
    fetchKeeperChatHistory.mockReturnValueOnce(original.promise).mockImplementationOnce(() => {
      replacementStarted.resolve(undefined)
      return replacement.promise
    })
    const hydration = hydrateKeeperChatHistory('echo', { force })
    storeDraft()
    fetchKeeperChatOperation.mockResolvedValue({ operationId: 'restored-op', state: {
      kind: 'succeeded', completedAt: 2, outcomeRef: 'result',
    } })
    const reconciliation = hydrateTrackedKeeperChatOperations('echo')
    await replacementStarted.promise
    return { original, replacement, hydration, reconciliation }
  }

  it('keeps previously hydrated membership and the failure banner after replacement failure', async () => {
    fetchKeeperChatHistory.mockResolvedValueOnce([historyMessage('known-history', 'known')])
    await hydrateKeeperChatHistory('echo')
    const { original, replacement, hydration, reconciliation } = await startReplacement(true)
    replacement.reject(new Error('replacement refresh failed'))
    await reconciliation
    original.reject(new Error('superseded refresh failed'))
    await hydration

    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo).toContain('replacement refresh failed')
    expect(keeperHydrating.value.echo).toBe(false)
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'known-history')).toBe(true)
    expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(1)
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(3)
  })

  it('does not let a superseded reconciliation failure settle a newer hydration owner', async () => {
    const { original, replacement, hydration, reconciliation } = await startReplacement()
    const latest = deferred<KeeperChatHistoryMessage[]>()
    fetchKeeperChatHistory.mockReturnValueOnce(latest.promise)
    const latestHydration = hydrateKeeperChatHistory('echo', { force: true })
    replacement.reject(new Error('superseded reconciliation failed'))
    await reconciliation
    original.resolve([historyMessage('stale-first-history', 'stale')])
    await hydration

    expect(keeperHydrating.value.echo).toBe(true)
    expect(keeperChatHistoryHydration.value.echo).toBeUndefined()
    expect(keeperChatHistoryErrors.value.echo).toBeUndefined()
    expect(fetchKeeperToolCalls).not.toHaveBeenCalled()
    latest.resolve([historyMessage('latest-history', 'latest', 3)])
    await latestHydration
    expect(keeperHydrating.value.echo).toBe(false)
    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'latest-history')).toBe(true)
    expect(keeperThreads.value.echo?.some(entry => entry.id === 'stale-first-history')).toBe(false)
  })

  it('settles successful empty replacement history before its canonical operation arrives', async () => {
    const { original, replacement, hydration, reconciliation } = await startReplacement()
    replacement.resolve([])
    await reconciliation
    original.reject(new Error('superseded first hydration failed'))
    await hydration

    expect(keeperChatHistoryHydration.value.echo).toBe('hydrated')
    expect(keeperChatHistoryErrors.value.echo).toBeNull()
    expect(keeperHydrating.value.echo).toBe(false)
    expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(1)
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.delivery).toBe('delivered')
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
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
  it.each(['none', 'user', 'both'] as const)('releases tracking while retaining canonical rows already observed (%s)', async preloaded => {
    storeDraft()
    if (preloaded !== 'none') {
      appendThreadEntry('echo', {
        id: 'canonical-user', role: 'user', source: 'direct_user', label: 'You', text: 'input',
        delivery: 'history', deliveryProvenance: operationDeliveryProvenance('restored-op', 'accepted_user'),
      })
    }
    if (preloaded === 'both') {
      appendThreadEntry('echo', {
        id: 'canonical-assistant', role: 'assistant', source: 'direct_assistant', label: 'echo', text: '',
        rawText: 'partial authored answer', timestamp: '2026-10-11T00:00:00Z', delivery: 'queued',
        traceSteps: [{ kind: 'think', text: 'exposed reasoning' }],
        details: { turnOutcome: 'waiting_for_input', replyText: 'Which branch?' },
        deliveryProvenance: operationDeliveryProvenance('restored-op', 'terminal_result'),
      })
    }
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
    expect(requiredFixture(keeperThreads.value.echo).filter(entry => entry.role === 'user')).toMatchObject([
      { id: 'canonical-user', text: 'input' },
    ])
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
