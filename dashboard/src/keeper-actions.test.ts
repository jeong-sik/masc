import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { callMcpTool } = vi.hoisted(() => ({ callMcpTool: vi.fn() }))
const { runOperatorAction } = vi.hoisted(() => ({ runOperatorAction: vi.fn() }))
const { invalidateDashboardCache, refreshDashboard } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))
const {
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult,
  isTerminalQueuedKeeperMessage,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  streamKeeperMessage,
} = vi.hoisted(() => ({
  cancelQueuedKeeperMessage: vi.fn(async () => undefined),
  fetchKeeperChatHistory: vi.fn(),
  fetchQueuedKeeperMessageResult: vi.fn(),
  isTerminalQueuedKeeperMessage: vi.fn((result: { status: string }) => (
    result.status === 'done'
    || result.status === 'error'
    || result.status === 'lost'
    || result.status === 'cancelled'
  )),
  queuedKeeperMessageError: vi.fn((result: { status: string }) => `request ${result.status}`),
  queuedKeeperMessageToReply: vi.fn((result: { result?: { reply?: string } }) => ({
    text: result.result?.reply ?? '(empty reply)',
    details: null,
  })),
  streamKeeperMessage: vi.fn(),
}))

vi.mock('./api/mcp', () => ({ callMcpTool }))
vi.mock('./api/core', () => ({ runOperatorAction }))
vi.mock('./api/keeper', () => ({
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult,
  isTerminalQueuedKeeperMessage,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  streamKeeperMessage,
}))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard }))

import {
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperStatusDetails,
  keeperThreads,
} from './keeper-state'
import {
  _resetChatHydrationForTests,
  dispatchKeeperInterjectAction,
  hydrateKeeperChatHistory,
  hydrateKeeperStatus,
  loadFullKeeperHistory,
  noteKeeperChatAppended,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  resumePendingKeeperChatRequests,
  selectKeeper,
  sendKeeperThreadMessage,
} from './keeper-actions'
import {
  _clearPendingKeeperChatRequestsForTests,
  pendingKeeperChatRequestsForKeeper,
  upsertPendingKeeperChatRequest,
} from './keeper-chat-pending'
import { KEEPER_HISTORY_TAIL_MESSAGES } from './config/constants'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperStatusDetail } from './types'

describe('noteKeeperChatAppended', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('skips keepers whose transcript was never hydrated', async () => {
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
  })

  it('debounces a burst of appends into one forced refetch', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
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
})

describe('hydrateKeeperChatHistory', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
  })

  it('merges the server transcript into the thread', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(2)
    expect(thread[0]?.delivery).toBe('history')
    expect(thread[1]?.role).toBe('assistant')
  })

  it('fetches only once per keeper per page lifetime', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])

    await hydrateKeeperChatHistory('echo')
    await hydrateKeeperChatHistory('echo')

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })

  it('allows a retry after a failed fetch', async () => {
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')
    expect(keeperActionErrors.value.echo).toContain('이전 대화 불러오기 실패')

    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.echo).toHaveLength(1)
  })
})

describe('sendKeeperThreadMessage stream outcome', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    _clearPendingKeeperChatRequestsForTests()
    streamKeeperMessage.mockReset()
    fetchKeeperChatHistory.mockReset()
    fetchQueuedKeeperMessageResult.mockReset()
    isTerminalQueuedKeeperMessage.mockClear()
    queuedKeeperMessageError.mockClear()
    queuedKeeperMessageToReply.mockClear()
    queuedKeeperMessageError.mockImplementation((result: { status: string }) => `request ${result.status}`)
    queuedKeeperMessageToReply.mockImplementation((result: { result?: { reply?: string } }) => ({
      text: result.result?.reply ?? '(empty reply)',
      details: null,
    }))
    refreshDashboard.mockClear()
    invalidateDashboardCache.mockClear()
  })

  function emitting(events: KeeperChatStreamEvent[], terminal: boolean) {
    return async (
      _name: string,
      _message: string,
      opts: { onEvent: (event: KeeperChatStreamEvent) => void },
    ) => {
      for (const event of events) opts.onEvent(event)
      return { terminal }
    }
  }

  it('marks the reply interrupted when the stream ends without a terminal event', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_START' },
      { type: 'TEXT_MESSAGE_CONTENT', delta: '부분 응답' },
    ], false))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('interrupted')
    expect(reply?.text).toContain('부분 응답')
    expect(reply?.error).toContain('끊겼습니다')
    expect(keeperActionErrors.value.echo).toContain('끊겼습니다')
  })

  it('delivers normally on RUN_FINISHED and does not force a dashboard refresh', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_START' },
      { type: 'TEXT_MESSAGE_CONTENT', delta: '완료된 응답' },
      { type: 'TEXT_MESSAGE_END' },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('delivered')
    expect(reply?.text).toContain('완료된 응답')
    // Regression guard: the per-message force refresh re-rendered the
    // whole dashboard after every chat send (user-visible "refresh").
    expect(refreshDashboard).not.toHaveBeenCalled()
    expect(invalidateDashboardCache).not.toHaveBeenCalled()
  })

  it('keeps a queued request resumable when the stream cuts before terminal', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      {
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_1', status: 'queued' },
      },
    ], false))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    expect(pendingKeeperChatRequestsForKeeper('echo')).toMatchObject([
      { requestId: 'kmsg_echo_1', keeperName: 'echo', message: '진행 상황?' },
    ])
  })

  it('resumes a pending request from storage and finalizes the transcript', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '어디까지 했어?',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockResolvedValue({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      status: 'done',
      ok: true,
      result: { reply: '여기까지 했습니다.' },
    })
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', '어디까지 했어?', 'delivered'],
      ['assistant', '여기까지 했습니다.', 'delivered'],
    ])
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
  })

  it('drops a stale pending request when the server no longer knows request_id', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '어디까지 했어?',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockRejectedValue(
      new Error(
        'GET /api/v1/gate/message/requests/kmsg_echo_1: {"error":{"message":"request_id not found"}}',
      ),
    )
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect(keeperThreads.value.echo).toEqual([])
    expect(keeperActionErrors.value.echo).toBeNull()
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })
})

// ─── Status / runtime actions (exports untested before this block) ──

// Raw diagnostic that survives normalizeKeeperDiagnostic — all three
// required fields must be valid union members or the whole diagnostic
// is rejected (keeper-state.ts:169-178).
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

  it('dispatches kind=send through the thread-message path with trimmed values', async () => {
    streamKeeperMessage.mockResolvedValue({ terminal: true })

    await dispatchKeeperInterjectAction({ kind: 'send', keeperName: '  echo  ', message: '  hi  ' })

    expect(streamKeeperMessage).toHaveBeenCalledWith('echo', 'hi', expect.objectContaining({
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
      include_memory_bank: false,
      include_history_tail: false,
      include_compaction_history: false,
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
      include_memory_bank: false,
      include_history_tail: true,
      include_compaction_history: false,
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
