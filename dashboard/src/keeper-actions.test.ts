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
  queuedKeeperMessageToReply: vi.fn((result: { result?: { reply?: string } }): KeeperToolReply => ({
    text: result.result?.reply ?? '(empty reply)',
    details: null,
  })),
  streamKeeperMessage: vi.fn(),
}))
const { fetchKeeperToolCalls } = vi.hoisted(() => ({
  fetchKeeperToolCalls: vi.fn(async (): Promise<{ entries: ToolCallEntry[] }> => ({ entries: [] })),
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
vi.mock('./api/dashboard', () => ({ fetchKeeperToolCalls }))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard }))

import {
  _resetLiveSendRequestOwnersForTests,
  activeStreamEntryId,
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperThreads,
  activeStreamRequestId,
} from './keeper-state'
import {
  _resetCancelledKeeperThreadRequestsForTests,
  _resetKeeperThreadMessageSendGuardsForTests,
  _resetChatHydrationForTests,
  cancelActiveKeeperThreadMessage,
  dispatchKeeperInterjectAction,
  hydrateKeeperChatHistory,
  hydrateKeeperStatus,
  isKeeperThreadMessageSendInFlight,
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
import {
  resetToolCallOutputs,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from './tool-call-output-store'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperToolReply } from './api/keeper'
import type { ToolCallEntry } from './api/dashboard'
import type { KeeperConversationAttachment, KeeperStatusDetail } from './types'

beforeEach(() => {
  fetchKeeperToolCalls.mockReset()
  fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
  resetToolCallOutputs()
})

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

  it('still refreshes history when an audio clip is attached', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
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
    _resetKeeperThreadMessageSendGuardsForTests()
    _resetLiveSendRequestOwnersForTests()
    _resetCancelledKeeperThreadRequestsForTests()
    streamKeeperMessage.mockReset()
    cancelQueuedKeeperMessage.mockReset()
    cancelQueuedKeeperMessage.mockResolvedValue(undefined)
    fetchKeeperChatHistory.mockReset()
    fetchQueuedKeeperMessageResult.mockReset()
    isTerminalQueuedKeeperMessage.mockClear()
    queuedKeeperMessageError.mockClear()
    queuedKeeperMessageToReply.mockClear()
    queuedKeeperMessageError.mockImplementation((result: { status: string }) => `request ${result.status}`)
    queuedKeeperMessageToReply.mockImplementation((result: { result?: { reply?: string } }): KeeperToolReply => ({
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

  function abortError(): Error {
    const err = new Error('Aborted')
    err.name = 'AbortError'
    return err
  }

  it('does not content-deduplicate repeated same-text sends', async () => {
    streamKeeperMessage
      .mockImplementationOnce(async (
        _name: string,
        _message: string,
        opts: { signal?: AbortSignal },
      ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      }))
      .mockResolvedValueOnce({ terminal: true })

    const firstSend = sendKeeperThreadMessage('echo', '진행 상황?').catch(err => err)
    await Promise.resolve()

    await sendKeeperThreadMessage('echo', '진행 상황?')

    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
    expect((keeperThreads.value.echo ?? []).filter(entry => entry.role === 'user')).toHaveLength(2)
    expect((keeperThreads.value.echo ?? []).filter(entry => entry.role === 'assistant')).toHaveLength(2)
    const firstError = await firstSend
    expect(firstError).toBeInstanceOf(Error)
    expect(firstError.name).toBe('AbortError')
  })

  it('dedupes repeated firing of the same client action id while in flight', async () => {
    let resolveStream: (outcome: { terminal: boolean }) => void = () => {}
    streamKeeperMessage
      .mockImplementationOnce(async () => new Promise<{ terminal: boolean }>(resolve => {
        resolveStream = resolve
      }))
      .mockResolvedValueOnce({ terminal: true })

    const firstSend = sendKeeperThreadMessage('echo', '진행 상황?', {
      clientActionId: 'send-button-click-1',
    })
    await Promise.resolve()

    await sendKeeperThreadMessage('echo', '진행 상황?', {
      clientActionId: 'send-button-click-1',
    })

    expect(streamKeeperMessage).toHaveBeenCalledTimes(1)
    expect((keeperThreads.value.echo ?? []).filter(entry => entry.role === 'assistant')).toHaveLength(1)

    resolveStream({ terminal: true })
    await firstSend

    await sendKeeperThreadMessage('echo', '진행 상황?', {
      clientActionId: 'send-button-click-2',
    })
    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
  })

  it('keeps another keeper lane available while one keeper stream is in flight', async () => {
    let resolveEcho: (outcome: { terminal: boolean }) => void = () => {}
    streamKeeperMessage.mockImplementation(async (
      name: string,
      _message: string,
      opts: { onEvent: (event: KeeperChatStreamEvent) => void },
    ) => {
      if (name === 'echo') {
        opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: 'echo reply' })
        return new Promise<{ terminal: boolean }>(resolve => {
          resolveEcho = resolve
        })
      }
      opts.onEvent({ type: 'TEXT_MESSAGE_CONTENT', delta: `${name} reply` })
      return { terminal: true }
    })

    const echoSend = sendKeeperThreadMessage('echo', 'slow turn')
    await Promise.resolve()

    expect(keeperSending.value.echo).toBe(true)
    expect(activeStreamEntryId('echo')).not.toBeNull()

    await sendKeeperThreadMessage('rama', 'status?')

    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
    expect(streamKeeperMessage.mock.calls.map(call => call[0])).toEqual(['echo', 'rama'])
    expect(keeperSending.value.echo).toBe(true)
    expect(activeStreamEntryId('echo')).not.toBeNull()
    expect(keeperSending.value.rama).toBe(false)
    expect(activeStreamEntryId('rama')).toBeNull()
    expect((keeperThreads.value.rama ?? []).map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', 'status?', 'delivered'],
      ['assistant', 'rama reply', 'delivered'],
    ])

    resolveEcho({ terminal: true })
    await echoSend

    expect(keeperSending.value.echo).toBe(false)
    expect(activeStreamEntryId('echo')).toBeNull()
  })

  it('keeps queued client action ids guarded while a batched queue send is in flight', async () => {
    let resolveStream: (outcome: { terminal: boolean }) => void = () => {}
    streamKeeperMessage.mockImplementationOnce(async () => new Promise<{ terminal: boolean }>(resolve => {
      resolveStream = resolve
    }))

    const firstSend = sendKeeperThreadMessage('echo', 'queued drafts', {
      clientActionIds: ['queue-click-1', 'queue-click-2'],
    })
    await Promise.resolve()

    expect(isKeeperThreadMessageSendInFlight('echo', 'queue-click-1')).toBe(true)
    expect(isKeeperThreadMessageSendInFlight('echo', 'queue-click-2')).toBe(true)

    await sendKeeperThreadMessage('echo', 'queued drafts', {
      clientActionId: 'queue-click-1',
    })

    expect(streamKeeperMessage).toHaveBeenCalledTimes(1)

    resolveStream({ terminal: true })
    await firstSend

    expect(isKeeperThreadMessageSendInFlight('echo', 'queue-click-1')).toBe(false)
    expect(isKeeperThreadMessageSendInFlight('echo', 'queue-click-2')).toBe(false)
  })

  it('does not suppress the same text when the attachment payload differs', async () => {
    const firstAttachment: KeeperConversationAttachment = {
      id: 'att-first',
      type: 'image',
      name: 'first.png',
      size: 128,
      mimeType: 'image/png',
      data: 'data:image/png;base64,first',
    }
    const secondAttachment: KeeperConversationAttachment = {
      id: 'att-second',
      type: 'image',
      name: 'second.png',
      size: 256,
      mimeType: 'image/png',
      data: 'data:image/png;base64,second',
    }
    streamKeeperMessage
      .mockImplementationOnce(async (
        _name: string,
        _message: string,
        opts: { signal?: AbortSignal },
      ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      }))
      .mockResolvedValueOnce({ terminal: true })

    const firstSend = sendKeeperThreadMessage('echo', 'describe this', {
      attachments: [firstAttachment],
    }).catch(err => err)
    await Promise.resolve()

    await sendKeeperThreadMessage('echo', 'describe this', {
      attachments: [secondAttachment],
    })

    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
    expect(streamKeeperMessage.mock.calls[1]?.[2]).toEqual(expect.objectContaining({
      attachments: [secondAttachment],
    }))
    const firstError = await firstSend
    expect(firstError).toBeInstanceOf(Error)
    expect(firstError.name).toBe('AbortError')
  })

  it('keeps a replacement stream active when the superseded send aborts later', async () => {
    let resolveSecond: (outcome: { terminal: boolean }) => void = () => {}
    streamKeeperMessage
      .mockImplementationOnce(async (
        _name: string,
        _message: string,
        opts: { signal?: AbortSignal },
      ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      }))
      .mockImplementationOnce(async () => new Promise<{ terminal: boolean }>(resolve => {
        resolveSecond = resolve
      }))

    const firstSend = sendKeeperThreadMessage('echo', 'first').catch(err => err)
    await Promise.resolve()

    const secondSend = sendKeeperThreadMessage('echo', 'second')
    await Promise.resolve()

    const firstError = await firstSend
    expect(firstError).toBeInstanceOf(Error)
    expect(firstError.name).toBe('AbortError')
    expect(streamKeeperMessage).toHaveBeenCalledTimes(2)
    expect(keeperSending.value.echo).toBe(true)
    const activeAssistant = (keeperThreads.value.echo ?? [])
      .find(entry => entry.role === 'assistant' && entry.delivery === 'sending')
    expect(activeStreamEntryId('echo')).toBe(activeAssistant?.id)

    resolveSecond({ terminal: true })
    await secondSend
    expect(keeperSending.value.echo).toBe(false)
    expect(activeStreamEntryId('echo')).toBeNull()
  })

  it('cancels the server keeper request immediately when the operator aborts an active stream', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        signal?: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_1', status: 'queued' },
      })
      return new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      })
    })

    const sendPromise = sendKeeperThreadMessage('echo', 'stuck turn').catch(err => err)
    await Promise.resolve()

    await cancelActiveKeeperThreadMessage('echo')

    expect(cancelQueuedKeeperMessage).toHaveBeenCalledTimes(1)
    expect(cancelQueuedKeeperMessage).toHaveBeenCalledWith(
      'kmsg_echo_1',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    const err = await sendPromise
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
  })

  it('reports failure and keeps the pending request when server cancel fails', async () => {
    cancelQueuedKeeperMessage.mockRejectedValue(new Error('network down'))
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        signal?: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_retry', status: 'queued' },
      })
      return new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      })
    })

    const sendPromise = sendKeeperThreadMessage('echo', 'stuck turn').catch(err => err)
    await Promise.resolve()

    await expect(cancelActiveKeeperThreadMessage('echo')).resolves.toBe(true)
    expect(cancelQueuedKeeperMessage).toHaveBeenCalledTimes(1)
    await vi.waitFor(() => expect(keeperActionErrors.value.echo).toContain('network down'))
    expect(pendingKeeperChatRequestsForKeeper('echo')).toHaveLength(1)
    expect(keeperSending.value.echo).toBe(false)
    expect(activeStreamEntryId('echo')).toBeNull()

    const err = await sendPromise
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
    expect(activeStreamRequestId('echo')).toBeNull()
  })

  it('aborts the local stream before backend cancel settles', async () => {
    cancelQueuedKeeperMessage.mockImplementation(() => new Promise(() => {}))
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        signal?: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_hung_cancel', status: 'queued' },
      })
      return new Promise<{ terminal: boolean }>((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
      })
    })

    const sendPromise = sendKeeperThreadMessage('echo', 'stuck turn').catch(err => err)
    await Promise.resolve()

    await expect(cancelActiveKeeperThreadMessage('echo')).resolves.toBe(true)

    expect(cancelQueuedKeeperMessage).toHaveBeenCalledWith(
      'kmsg_echo_hung_cancel',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    expect(keeperSending.value.echo).toBe(false)
    expect(activeStreamEntryId('echo')).toBeNull()
    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('cancelled')

    const err = await sendPromise
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
  })

  it('aborts locally without server cancel when no request id has arrived yet', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: { signal?: AbortSignal },
    ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
      opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
    }))

    const sendPromise = sendKeeperThreadMessage('echo', 'still opening').catch(err => err)
    await Promise.resolve()

    await expect(cancelActiveKeeperThreadMessage('echo')).resolves.toBe(true)
    expect(cancelQueuedKeeperMessage).not.toHaveBeenCalled()
    const err = await sendPromise
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
  })

  it('cancels the backend request if queue id arrives after local abort', async () => {
    const controls: { emitQueueRequest?: () => void } = {}
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        signal?: AbortSignal
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => new Promise<{ terminal: boolean }>((_resolve, reject) => {
      controls.emitQueueRequest = () => {
        opts.onEvent({
          type: 'CUSTOM',
          name: 'KEEPER_QUEUE_REQUEST',
          value: { request_id: 'kmsg_echo_late', status: 'queued' },
        })
      }
      opts.signal?.addEventListener('abort', () => { reject(abortError()) }, { once: true })
    }))

    const sendPromise = sendKeeperThreadMessage('echo', 'still opening').catch(err => err)
    await Promise.resolve()

    await expect(cancelActiveKeeperThreadMessage('echo')).resolves.toBe(true)
    controls.emitQueueRequest?.()
    await Promise.resolve()

    expect(cancelQueuedKeeperMessage).toHaveBeenCalledWith(
      'kmsg_echo_late',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    const err = await sendPromise
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
  })

  it('uses a fresh timeout signal when cancelling after an abort error', async () => {
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: {
        onEvent: (event: KeeperChatStreamEvent) => void
      },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_signal', status: 'running' },
      })
      throw abortError()
    })

    const err = await sendKeeperThreadMessage('echo', 'stream abort').catch(error => error)

    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('AbortError')
    expect(cancelQueuedKeeperMessage).toHaveBeenCalledTimes(1)
    const [requestId, opts] =
      cancelQueuedKeeperMessage.mock.calls[0] as unknown as [string, { signal?: AbortSignal }]
    expect(requestId).toBe('kmsg_echo_signal')
    const signal = opts.signal
    expect(signal).toBeInstanceOf(AbortSignal)
    expect(signal?.aborted).toBe(false)
  })

  it('does not duplicate the pending assistant when a live send is still streaming and the panel remounts', async () => {
    // A send whose SSE stream stays open (reply pending). The mock fires the
    // queue-request event synchronously, then returns a promise we resolve
    // only at cleanup, so the send is still in-flight during the "remount".
    let resolveStream: (outcome: { terminal: boolean }) => void = () => {}
    streamKeeperMessage.mockImplementation(async (
      _name: string,
      _message: string,
      opts: { onEvent: (event: KeeperChatStreamEvent) => void },
    ) => {
      opts.onEvent({
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_1', status: 'queued' },
      })
      return new Promise<{ terminal: boolean }>(resolve => {
        resolveStream = resolve
      })
    })

    // Start the send without awaiting — the stream stays live.
    const sendPromise = sendKeeperThreadMessage('echo', '진행 상황?')
    await Promise.resolve()

    // Preconditions: one optimistic assistant entry + the request persisted.
    const before = (keeperThreads.value.echo ?? []).filter(e => e.role === 'assistant')
    expect(before).toHaveLength(1)
    expect(before[0]?.id).toMatch(/^reply-\d+-\d+$/)
    expect(before[0]?.delivery).toBe('queued')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toHaveLength(1)

    // SPA remount: the mount effect re-runs resume while the send is live.
    await resumePendingKeeperChatRequests('echo')

    // Fix: no second handler — exactly one assistant entry, no pending-* twin,
    // and resume started no competing poll loop for the owned request.
    const after = (keeperThreads.value.echo ?? []).filter(e => e.role === 'assistant')
    expect(after).toHaveLength(1)
    expect(after.some(e => e.id === 'pending-assistant-kmsg_echo_1')).toBe(false)
    expect(fetchQueuedKeeperMessageResult).not.toHaveBeenCalled()

    // Cleanup: end the stream terminally so the send settles.
    resolveStream({ terminal: true })
    await sendPromise
  })

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

  it('hydrates tool outputs when a live stream finishes a tool call', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TOOL_CALL_START', toolCallId: 'tc-1', toolCallName: 'keeper_board_list' },
      { type: 'TOOL_CALL_END', toolCallId: 'tc-1' },
      { type: 'TEXT_MESSAGE_START' },
      { type: 'TEXT_MESSAGE_CONTENT', delta: '완료' },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    expect(fetchKeeperToolCalls).toHaveBeenCalledWith('echo', 200)
  })

  it('does not render generic empty-reply text after a tool-only terminal turn', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TOOL_CALL_START', toolCallId: 'tc-1', toolCallName: 'keeper_board_list' },
      { type: 'TOOL_CALL_END', toolCallId: 'tc-1' },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('delivered')
    expect(reply?.text).toBe('Tool-only turn ended without a final reply.')
    expect(fetchKeeperToolCalls).toHaveBeenCalledWith('echo', 200)
  })

  it('marks a terminal no-visible reply as error instead of empty reply text', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      {
        type: 'CUSTOM',
        name: 'KEEPER_REPLY_DETAILS',
        value: {
          runtime_class: 'keeper',
          reply: '',
          turn_outcome: 'no_visible_reply',
        },
      },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', '뭐함')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('error')
    expect(reply?.text).toContain('표시할 답변')
    expect(reply?.text).not.toBe('(empty reply)')
    expect(keeperActionErrors.value.echo).toContain('표시할 답변')
  })

  it('derives text and media user blocks when only attachments are supplied', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_END' },
      { type: 'RUN_FINISHED' },
    ], true))
    const attachments: KeeperConversationAttachment[] = [
      {
        id: 'att-img',
        type: 'image',
        name: 'screen.png',
        size: 1024,
        mimeType: 'image/png',
        data: 'data:image/png;base64,abc123',
      },
    ]

    await sendKeeperThreadMessage('echo', 'describe this', { attachments })

    expect(streamKeeperMessage).toHaveBeenCalledWith(
      'echo',
      'describe this',
      expect.objectContaining({
        attachments,
        userBlocks: [
          {
            type: 'image',
            attachmentId: 'att-img',
            name: 'screen.png',
            mimeType: 'image/png',
            size: 1024,
          },
          { type: 'text', text: 'describe this' },
        ],
      }),
    )
  })

  it('derives audio user blocks from audio attachments', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_END' },
      { type: 'RUN_FINISHED' },
    ], true))
    const attachments: KeeperConversationAttachment[] = [
      {
        id: 'att-audio',
        type: 'file',
        name: 'voice.webm',
        size: 2048,
        mimeType: 'audio/webm',
        data: 'data:audio/webm;base64,AAAA',
      },
    ]

    await sendKeeperThreadMessage('echo', '', { attachments })

    expect(streamKeeperMessage).toHaveBeenCalledWith(
      'echo',
      '[첨부 1개: voice.webm]',
      expect.objectContaining({
        attachments,
        userBlocks: [
          {
            type: 'audio',
            attachmentId: 'att-audio',
            name: 'voice.webm',
            mimeType: 'audio/webm',
            size: 2048,
          },
        ],
      }),
    )
  })

  it('mints deterministic non-colliding optimistic entry ids', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_END' },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', 'hi')

    const thread = keeperThreads.value.echo ?? []
    const user = thread.find(entry => entry.role === 'user')
    const assistant = thread.find(entry => entry.role === 'assistant')
    expect(user?.id).toMatch(/^local-\d+-\d+$/)
    expect(assistant?.id).toMatch(/^reply-\d+-\d+$/)
    expect(user?.id).not.toBe(assistant?.id)
  })

  it('polls a queued request immediately when the stream cuts before terminal', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      {
        type: 'CUSTOM',
        name: 'KEEPER_QUEUE_REQUEST',
        value: { request_id: 'kmsg_echo_1', status: 'queued' },
      },
    ], false))
    fetchQueuedKeeperMessageResult.mockResolvedValue({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      status: 'done',
      ok: true,
      result: { reply: 'polling으로 복구됨' },
    })
    fetchKeeperChatHistory.mockResolvedValue([])

    await sendKeeperThreadMessage('echo', '진행 상황?')

    expect(fetchQueuedKeeperMessageResult).toHaveBeenCalledWith('kmsg_echo_1')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', '진행 상황?', 'delivered'],
      ['assistant', 'polling으로 복구됨', 'delivered'],
    ])
  })

  it('reconciles a stream network failure when the server history has the completed reply', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-06-15T13:08:38Z'))
    try {
      streamKeeperMessage.mockRejectedValue(new TypeError('network error'))
      fetchKeeperChatHistory.mockResolvedValue([
        { role: 'user', content: '진행 상황?', ts: 1_781_528_918 },
        { role: 'assistant', content: '서버에는 답변이 저장됐습니다.', ts: 1_781_528_920 },
      ])

      await sendKeeperThreadMessage('echo', '진행 상황?')

      const thread = keeperThreads.value.echo ?? []
      expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
        ['user', '진행 상황?', 'history'],
        ['assistant', '서버에는 답변이 저장됐습니다.', 'history'],
      ])
      expect(keeperActionErrors.value.echo).toBeNull()
    } finally {
      vi.useRealTimers()
    }
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

  it('resumes a no-visible pending request as error instead of blank assistant text', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '뭐함',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockResolvedValue({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      status: 'done',
      ok: true,
      result: {
        reply: '',
        turn_outcome: 'no_visible_reply',
      },
    })
    queuedKeeperMessageToReply.mockImplementation(() => ({
      text: '',
      details: {
        traceId: null,
        turnRef: null,
        providerMessageId: null,
        generation: null,
        modelUsed: null,
        stopReason: null,
        latencyMs: null,
        costUsd: null,
        usage: null,
        skillPrimary: null,
        skillReason: null,
        stateBlock: null,
        replyText: null,
        turnOutcome: 'no_visible_reply',
        rawPayload: {
          reply: '',
          turn_outcome: 'no_visible_reply',
        },
      },
    }))
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', '뭐함', 'error'],
      ['assistant', expect.stringContaining('표시할 답변'), 'error'],
    ])
    expect(thread.find(entry => entry.role === 'assistant')?.text).not.toBe('(empty reply)')
    expect(keeperActionErrors.value.echo).toContain('표시할 답변')
  })

  it('resumes repeated same-message sends as distinct request ids', async () => {
    const submittedAt = Date.UTC(2026, 5, 15, 9, 0, 0)
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: 'status?',
      submittedAt,
    })
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_2',
      keeperName: 'echo',
      message: 'status?',
      submittedAt,
    })
    fetchQueuedKeeperMessageResult.mockImplementation(async (requestId: string) => ({
      requestId,
      keeperName: 'echo',
      status: 'done',
      ok: true,
      result: { reply: requestId === 'kmsg_echo_1' ? 'first reply' : 'second reply' },
    }))
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(fetchQueuedKeeperMessageResult).toHaveBeenCalledTimes(2)
    expect(fetchQueuedKeeperMessageResult).toHaveBeenNthCalledWith(1, 'kmsg_echo_1')
    expect(fetchQueuedKeeperMessageResult).toHaveBeenNthCalledWith(2, 'kmsg_echo_2')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect((keeperThreads.value.echo ?? []).map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', 'status?', 'delivered'],
      ['assistant', 'first reply', 'delivered'],
      ['user', 'status?', 'delivered'],
      ['assistant', 'second reply', 'delivered'],
    ])
  })

  it('marks a recovered orphan request as lost instead of polling forever', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '어디까지 했어?',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockResolvedValue({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      status: 'lost',
      result: {
        reason: 'keeper_msg request was accepted but no live worker owns it',
      },
    })
    queuedKeeperMessageError.mockImplementation((result: { status: string; result?: { reason?: string } }) => (
      result.result?.reason ?? 'request lost'
    ))
    queuedKeeperMessageToReply.mockImplementation((result: { result?: { reply?: string; reason?: string } }) => ({
      text: result.result?.reason ?? '(empty reply)',
      details: null,
    }))
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(fetchQueuedKeeperMessageResult).toHaveBeenCalledWith('kmsg_echo_1')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery, entry.error])).toEqual([
      ['user', '어디까지 했어?', 'error', 'keeper_msg request was accepted but no live worker owns it'],
      ['assistant', 'keeper_msg request was accepted but no live worker owns it', 'error', 'keeper_msg request was accepted but no live worker owns it'],
    ])
  })

  it('resumes a cancelled pending request without restoring an error bubble', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '뭘 해야하나',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockResolvedValue({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      status: 'cancelled',
      ok: false,
      result: {
        cancelled: true,
        reason: 'keeper_msg request was cancelled by operator',
        cancelled_by: 'operator',
      },
    })
    queuedKeeperMessageError.mockImplementation(() => '요청이 취소되었습니다.')
    queuedKeeperMessageToReply.mockImplementation(() => ({
      text: '요청이 취소되었습니다.',
      details: null,
    }))
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(fetchQueuedKeeperMessageResult).toHaveBeenCalledWith('kmsg_echo_1')
    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect(keeperActionErrors.value.echo).toBeNull()
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery, entry.error])).toEqual([
      ['user', '뭘 해야하나', 'cancelled', null],
      ['assistant', '요청이 취소되었습니다.', 'cancelled', null],
    ])
  })

  it('keeps the user message visible when the server no longer knows request_id', async () => {
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
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', '어디까지 했어?', 'error'],
      ['assistant', '', 'error'],
    ])
    expect(keeperActionErrors.value.echo).toContain('서버 재시작')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })

  it('finalizes the pending message as error when the poll request times out', async () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: '어디까지 했어?',
      submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
    })
    fetchQueuedKeeperMessageResult.mockRejectedValue(
      new Error('GET /api/v1/gate/message/requests/kmsg_echo_1: timeout after 35000ms'),
    )
    fetchKeeperChatHistory.mockResolvedValue([])

    await resumePendingKeeperChatRequests('echo')

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect(keeperSending.value.echo).toBe(false)
    expect(keeperStreamStartedAt.value.echo).toBeNull()
    const thread = keeperThreads.value.echo ?? []
    expect(thread.map(entry => [entry.role, entry.text, entry.delivery])).toEqual([
      ['user', '어디까지 했어?', 'error'],
      ['assistant', '', 'error'],
    ])
    expect(keeperActionErrors.value.echo).toContain('timeout after 35000ms')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })

  it('keeps the queued assistant after page reload while history has only the user message', async () => {
    vi.useFakeTimers()
    try {
      _resetChatHydrationForTests()
      _clearPendingKeeperChatRequestsForTests()
      upsertPendingKeeperChatRequest({
        requestId: 'kmsg_echo_1',
        keeperName: 'echo',
        message: '진행 상황?',
        submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
      })

      // Server already persisted the user turn, but the assistant reply is
      // still queued and has not been written yet.
      fetchKeeperChatHistory.mockResolvedValue([
        { role: 'user', content: '진행 상황?', ts: 1_780_000_000 },
      ])

      // First poll says queued; second poll completes so the test can finish.
      let pollCount = 0
      fetchQueuedKeeperMessageResult.mockImplementation(() => {
        pollCount += 1
        if (pollCount === 1) {
          return Promise.resolve({ status: 'queued' })
        }
        return Promise.resolve({ status: 'done', ok: true, result: { reply: '완료' } })
      })

      // Simulate the post-reload mount: hydrate history and resume pending
      // requests are kicked off concurrently by the panel effect.
      await hydrateKeeperChatHistory('echo')
      const resumePromise = resumePendingKeeperChatRequests('echo')

      // During the first sleep the assistant should still be queued.
      await vi.advanceTimersByTimeAsync(1_000)
      expect((keeperThreads.value.echo ?? []).some(entry => entry.role === 'assistant' && entry.delivery === 'queued')).toBe(true)

      // Let the resume loop finish.
      await vi.advanceTimersByTimeAsync(2_000)
      await resumePromise

      const thread = keeperThreads.value.echo ?? []
      expect(thread.filter(entry => entry.role === 'user')).toHaveLength(1)
      expect(thread.some(entry => entry.role === 'assistant' && entry.delivery === 'delivered')).toBe(true)
      expect(keeperActionErrors.value.echo).toBeNull()
    } finally {
      vi.useRealTimers()
    }
  })

  it('does not replace a queued assistant with an older empty-text history error', async () => {
    vi.useFakeTimers()
    try {
      _resetChatHydrationForTests()
      _clearPendingKeeperChatRequestsForTests()
      upsertPendingKeeperChatRequest({
        requestId: 'kmsg_echo_2',
        keeperName: 'echo',
        message: '진행 상황?',
        submittedAt: Date.UTC(2026, 5, 15, 9, 0, 0),
      })

      // History resolves after the resume loop has created pending entries,
      // so the merge races against the in-flight queued assistant. The older
      // history error has empty visible text (kept only because of its audio
      // clip), which would collide with the pending assistant under a naive
      // role+text dedup and cause the queued state to appear as an error.
      fetchKeeperChatHistory.mockImplementation(() => new Promise(resolve => {
        setTimeout(() => {
          resolve([
            { role: 'user', content: 'old question', ts: 1_700_000_000 },
            {
              role: 'assistant',
              content: '',
              ts: 1_700_000_001,
              kind: 'transport_failure',
              audio: {
                token: 'old-failure-clip',
                mime: 'audio/mpeg',
                duration_sec: 1,
                message_text: '',
              },
            },
          ])
        }, 100)
      }))

      // Keep queued for the race window, then complete so the test can end.
      let pollCount = 0
      fetchQueuedKeeperMessageResult.mockImplementation(() => {
        pollCount += 1
        if (pollCount === 1) {
          return Promise.resolve({ status: 'queued' })
        }
        return Promise.resolve({ status: 'done', ok: true, result: { reply: '완료' } })
      })

      const hydratePromise = hydrateKeeperChatHistory('echo')
      const resumePromise = resumePendingKeeperChatRequests('echo')

      // Let history resolve and merge while the assistant is still queued.
      await vi.advanceTimersByTimeAsync(200)
      await hydratePromise

      const thread = keeperThreads.value.echo ?? []
      const assistants = thread.filter(entry => entry.role === 'assistant')
      expect(assistants).toHaveLength(2)
      expect(assistants.some(entry => entry.delivery === 'queued')).toBe(true)
      expect(assistants.some(entry => entry.delivery === 'error')).toBe(true)
      expect(keeperActionErrors.value.echo).toBeNull()

      // Let the resume loop finish.
      await vi.advanceTimersByTimeAsync(2_000)
      await resumePromise
    } finally {
      vi.useRealTimers()
    }
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
