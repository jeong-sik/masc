import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

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
vi.mock('./api/core', () => ({ runOperatorAction }))
vi.mock('./api/keeper', () => ({
  cancelKeeperChatOperation,
  fetchKeeperChatOperation,
  fetchKeeperChatHistory,
  streamKeeperMessage,
}))
vi.mock('./api/dashboard', () => ({ fetchKeeperToolCalls }))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard, shellAuthSummary }))

import {
  _resetActiveKeeperStreamsForTests,
  _resetLiveSendRequestOwnersForTests,
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
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
  dispatchKeeperInterjectAction,
  hydrateKeeperChatHistory,
  hydrateKeeperStatus,
  loadFullKeeperHistory,
  noteKeeperChatAppended,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  refreshActiveKeeperChatHistory,
  selectKeeper,
  sendKeeperThreadMessage,
} from './keeper-actions'
import {
  _clearTrackedKeeperChatOperationsForTests,
} from './keeper-chat-operations-local'
import { KEEPER_HISTORY_TAIL_MESSAGES } from './config/constants'
import {
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
  shellAuthSummary.value = { effective_role: 'admin' }
  fetchKeeperToolCalls.mockReset()
  fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
  resetToolCallOutputs()
  _resetKeeperStreamBuffersForTests()
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
    expect(keeperActionErrors.value.echo).toContain('이전 대화 불러오기 실패')

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
          success: true,
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

  it('allows a retry after a failed fetch', async () => {
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { id: 'msg-retry-user', role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')
    expect(keeperActionErrors.value.echo).toContain('이전 대화 불러오기 실패')

    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.echo).toHaveLength(1)
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
          transcript_slot: { kind: 'terminal_assistant' },
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
