import { beforeEach, describe, expect, it } from 'vitest'
import {
  _resetActiveKeeperStreamsForTests,
  _resetLiveSendRequestOwnersForTests,
  activeStreamRequestId,
  appendThreadEntry,
  claimLiveSendRequest,
  clearActiveStream,
  markLiveSendRequestAccepted,
  setActiveStream,
} from './keeper-state'
import { keeperThreads, keeperToolApprovals } from './keeper-state'
import {
  _flushPendingKeeperStreamDeltasForTests,
  _resetKeeperStreamBuffersForTests,
  abortKeeperThreadMessage,
  applyKeeperOperationTurnEvent,
  applyKeeperStreamEvent,
} from './keeper-stream'
import { parseSSEMessage } from './schemas/sse'
import {
  operationDeliveryProvenance,
  isOperationDeliveryProvenance,
} from './keeper-delivery-provenance'
import {
  _clearTrackedKeeperChatOperationsForTests,
  trackedKeeperChatOperationsForKeeper,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'

function toolOccurrence(blockIndex = 0, streamScope = 0) {
  return { toolStreamScope: streamScope, toolCallBlockIndex: blockIndex }
}

function assistantEntry(operationId?: string): void {
  appendThreadEntry('sangsu', {
    id: 'reply-1',
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    text: '',
    rawText: '',
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: 'opening',
    ...(operationId
      ? { deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_assistant') }
      : {}),
    details: null,
  })
}

describe('Keeper operation stream projection', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    _resetLiveSendRequestOwnersForTests()
    _resetActiveKeeperStreamsForTests()
    _clearTrackedKeeperChatOperationsForTests()
    keeperThreads.value = {}
    keeperToolApprovals.value = {}
  })

  it('streams text into the selected assistant entry', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '안녕',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('안녕')
    expect(entry?.delivery).toBe('streaming')
  })

  it('resets unfinished narrative at a runtime attempt boundary and keeps tool evidence', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      messageId: 'failed-message',
      delta: 'failed reply',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'failed reasoning' },
    })
    _flushPendingKeeperStreamDeltasForTests()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(1),
      toolCallId: 'call-kept',
      toolCallName: 'Read',
    })

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_RUNTIME_ATTEMPT_STARTED',
      value: null,
    })).toBeNull()

    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.rawText).toBe('')
    expect(reply?.traceSteps).toEqual([
      expect.objectContaining({ kind: 'tool', toolCallId: 'call-kept' }),
    ])
    expect(
      keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'call-kept'),
    ).toBeDefined()
  })

  const streamMessageOnce = (): void => {
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-1' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: '네.' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: ' 현재 상태:' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_END', messageId: 'm-1' })
  }

  it('applies a full message sequence delivered twice exactly once', () => {
    assistantEntry()
    streamMessageOnce()
    streamMessageOnce()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.rawText).toBe('네. 현재 상태:')
  })

  it('drops content re-delivered after the message ended', () => {
    assistantEntry()
    streamMessageOnce()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: ' 현재 상태:' })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.rawText).toBe('네. 현재 상태:')
  })

  it('restarts the buffer when the in-flight message re-STARTs', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-1' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: '네.' })
    // The observer socket replays START+CONTENT for the same in-flight message.
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-1' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: '네.' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_END', messageId: 'm-1' })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.rawText).toBe('네.')
  })

  it('keeps two distinct messages in one entry (no false dedup)', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-1' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-1', delta: '첫째' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-2' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-2', delta: '둘째' })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.rawText).toBe('첫째둘째')
  })

  it('drops a custom event this view does not draw instead of ending the reply', () => {
    assistantEntry()
    // keeper-actions.ts throws on any string this returns, so a name with no
    // handler used to stop the stream mid-reply and the answer never landed.
    // #29650 added these two to the name list and the SSE field table but not
    // to the value union or to the handlers, so they decoded and then killed
    // the stream (rondo, 2026-08-24).
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: {
        tool_call_id: 'call-1',
        tool_call_name: 'Execute',
        args: '{}',
        question: 'run it?',
      },
    })).toBeNull()

    // The reply is still the one being streamed into.
    expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')).toBeDefined()
  })

  // task-343 regression: before the approval card existed, REQUESTED decoded
  // and then vanished (console.debug above) — the operator saw nothing while
  // the keeper held the call, and the wait retired itself 180s later as a
  // denial nobody chose. The stream projection must mint a pending approval
  // row the chat surface can draw and answer.
  it('mints a pending approval row on KEEPER_TOOL_APPROVAL_REQUESTED', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: {
        tool_call_id: 'call-approve-1',
        tool_call_name: 'Execute',
        args: '{"argv":["ls","-la"]}',
        question: 'Execute ls -la 를 실행할까요?',
      },
    })).toBeNull()

    const pending = keeperToolApprovals.value.sangsu?.['call-approve-1']
    expect(pending).toBeDefined()
    expect(pending?.toolName).toBe('Execute')
    expect(pending?.question).toBe('Execute ls -la 를 실행할까요?')
    expect(pending?.args).toBe('{"argv":["ls","-la"]}')
    expect(pending?.settled).toBe(false)
    expect(pending?.answering).toBe(false)
  })

  it('retires the approval row on KEEPER_TOOL_APPROVAL_SETTLED', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: {
        tool_call_id: 'call-settle-1',
        tool_call_name: 'Execute',
        args: '{}',
        question: 'run it?',
      },
    })
    expect(keeperToolApprovals.value.sangsu?.['call-settle-1']).toBeDefined()

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { tool_call_id: 'call-settle-1', outcome: 'Approved' },
    })).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.['call-settle-1']).toBeUndefined()
  })

  it('keeps the stream alive when a settle names a call this view never drew', () => {
    assistantEntry()
    // A wait answered from another window settles without a local REQUESTED;
    // the drop must be a no-op, not a stream-ending error.
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { tool_call_id: 'call-unknown-1', outcome: 'Denied' },
    })).toBeNull()
    expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')).toBeDefined()
  })

  it('projects queued acceptance without a receipt or queue revision', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: {
        operation_id: 'kmsg-operation-1',
        state: 'Queued',
        queued_count: 1,
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.deliveryProvenance).toEqual(
      operationDeliveryProvenance('kmsg-operation-1', 'terminal_assistant'),
    )
  })

  it('overlays partial delta usage onto the start snapshot instead of replacing it', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_START',
      value: {
        provider_message_id: 'msg-1',
        model: 'claude-sonnet-5',
        usage: {
          input_tokens: 60_882,
          output_tokens: 1,
          total_tokens: 60_883,
          cache_creation_input_tokens: 200,
          cache_read_input_tokens: 50_000,
        },
      },
    })
    // The classic wire shape: the final delta reports only the cumulative
    // output counter. It must not erase the start snapshot's counters.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_DELTA',
      value: { stop_reason: 'end_turn', usage: { output_tokens: 510 } },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.details?.usage).toMatchObject({
      inputTokens: 60_882,
      outputTokens: 510,
      totalTokens: 61_392,
      cacheCreationInputTokens: 200,
      cacheReadInputTokens: 50_000,
    })
  })

  it('routes server-pushed events by exact operation id', () => {
    for (const operationId of ['kmsg-operation-1', 'kmsg-operation-2']) {
      appendThreadEntry('sangsu', {
        id: `reply-${operationId}`,
        role: 'assistant',
        source: 'direct_assistant',
        label: 'sangsu',
        text: '',
        rawText: '',
        timestamp: null,
        deliveryProvenance: operationDeliveryProvenance(
          operationId,
          'terminal_assistant',
        ),
        delivery: 'queued',
        streamState: null,
        details: null,
      })
    }

    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-operation-2',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'second' },
    })

    const entries = keeperThreads.value.sangsu ?? []
    expect(entries.find(entry => isOperationDeliveryProvenance(
      entry.deliveryProvenance,
      'kmsg-operation-1',
      'terminal_assistant',
    ))?.text).toBe('')
    expect(entries.find(entry => isOperationDeliveryProvenance(
      entry.deliveryProvenance,
      'kmsg-operation-2',
      'terminal_assistant',
    ))?.text).toBe('second')
  })

  // The direct send stamps the accepted operation id onto the bubble it is
  // already streaming into (see [stampPlaceholderRequestId] in keeper-actions).
  // The server also broadcasts every operation event to all sessions, so the
  // same turn arrives twice in the tab that issued it. Both applications
  // append, so each fragment lands twice. The echo joins late and misses the
  // leading fragments, which puts the two copies out of phase -- that is why
  // the operator sees them interleaved rather than cleanly repeated.
  const directlyStreamingBubble = (): void => {
    appendThreadEntry('sangsu', {
      id: 'reply-1',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: null,
      deliveryProvenance: operationDeliveryProvenance(
        'kmsg-operation-1',
        'terminal_assistant',
      ),
      delivery: 'streaming',
      streamState: 'streaming',
      details: null,
    })
    // Mirrors keeper-actions: the direct send claims the accepted operation id.
    claimLiveSendRequest('kmsg-operation-1', 'sangsu')
    markLiveSendRequestAccepted('kmsg-operation-1')
  }

  // The server hands the very same AG-UI event to both transports
  // (server_routes_http_keeper_stream: broadcast then
  // publish_operation_live_event), so the echo carries an identical delta.
  it('ignores the broadcast echo of a turn the direct stream already owns', () => {
    directlyStreamingBubble()

    for (const delta of ['오퍼레이터가 ', '비유/', '빈정거림']) {
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta })
      applyKeeperOperationTurnEvent('sangsu', {
        operationId: 'kmsg-operation-1',
        event: { type: 'TEXT_MESSAGE_CONTENT', delta },
      })
    }

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('오퍼레이터가 비유/빈정거림')
  })

  it('claims ownership before the direct stream receives acceptance', () => {
    appendThreadEntry('sangsu', {
      id: 'reply-opening',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: null,
      deliveryProvenance: operationDeliveryProvenance(
        'kmsg-opening',
        'terminal_assistant',
      ),
      delivery: 'sending',
      streamState: 'opening',
      details: null,
    })
    setActiveStream(
      'sangsu',
      'kmsg-opening',
      'reply-opening',
      new AbortController(),
    )

    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-opening',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'observer raced acceptance' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-opening')
    expect(entry?.text).toBe('')
  })

  it('lets the observer resume an interrupted pre-acceptance placeholder', () => {
    appendThreadEntry('sangsu', {
      id: 'reply-interrupted',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: null,
      deliveryProvenance: operationDeliveryProvenance(
        'kmsg-interrupted',
        'terminal_assistant',
      ),
      delivery: 'interrupted',
      streamState: null,
      details: null,
    })

    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-interrupted',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'observer recovered' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-interrupted')
    expect(entry?.text).toBe('observer recovered')
    expect(entry?.delivery).toBe('streaming')
  })

  it('accepts observer events immediately after the direct owner exits', () => {
    directlyStreamingBubble()
    setActiveStream(
      'sangsu',
      'kmsg-operation-1',
      'reply-1',
      new AbortController(),
    )

    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-operation-1',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'owned echo' },
    })
    clearActiveStream('sangsu', 'kmsg-operation-1')
    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-operation-1',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'observer continuation' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('observer continuation')
  })

  // A late-attaching echo drops the leading fragments, so the two copies land
  // out of phase and read as interleaved rather than as a clean repetition --
  // this is the shape the operator reported.
  it('ignores a broadcast echo that joined the turn late', () => {
    directlyStreamingBubble()

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '오퍼레이터가 ',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '비유/',
    })
    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-operation-1',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: '비유/' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('오퍼레이터가 비유/')
  })

  it('ignores the broadcast echo of thinking deltas the direct stream already owns', () => {
    directlyStreamingBubble()

    // Both paths enqueue into one pending buffer keyed by keeper+entry, so an
    // echo appends into the same chunk array the direct stream is filling.
    for (const delta of ['오퍼레이터가 ', '비유/']) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta },
      })
      applyKeeperOperationTurnEvent('sangsu', {
        operationId: 'kmsg-operation-1',
        event: {
          type: 'CUSTOM',
          name: 'KEEPER_THINKING_DELTA',
          value: { index: 0, delta },
        },
      })
    }
    _flushPendingKeeperStreamDeltasForTests()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    const think = (entry?.traceSteps ?? []).filter(step => step.kind === 'think')
    expect(think.map(step => step.text)).toEqual(['오퍼레이터가 비유/'])
  })

  it('still applies broadcast events for a turn this session does not own', () => {
    appendThreadEntry('sangsu', {
      id: 'reply-1',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: null,
      deliveryProvenance: operationDeliveryProvenance(
        'kmsg-operation-1',
        'terminal_assistant',
      ),
      delivery: 'streaming',
      streamState: 'streaming',
      details: null,
    })

    applyKeeperOperationTurnEvent('sangsu', {
      operationId: 'kmsg-operation-1',
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'from another tab' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('from another tab')
  })

  it('keeps concurrent operation controllers independent', () => {
    const first = new AbortController()
    const second = new AbortController()
    setActiveStream('sangsu', 'kmsg-operation-1', 'reply-1', first)
    setActiveStream('sangsu', 'kmsg-operation-2', 'reply-2', second)
    markLiveSendRequestAccepted('kmsg-operation-1')
    markLiveSendRequestAccepted('kmsg-operation-2')

    abortKeeperThreadMessage('sangsu')

    expect(first.signal.aborted).toBe(true)
    expect(second.signal.aborted).toBe(false)
    expect(activeStreamRequestId('sangsu')).toBe('kmsg-operation-2')
  })

  it('does not return a later accepted request when aborting the first pre-acceptance stream', () => {
    const first = new AbortController()
    const second = new AbortController()
    setActiveStream('sangsu', 'kmsg-operation-1', 'reply-1', first)
    setActiveStream('sangsu', 'kmsg-operation-2', 'reply-2', second)
    markLiveSendRequestAccepted('kmsg-operation-2')

    const aborted = abortKeeperThreadMessage('sangsu')

    expect(aborted?.requestId).toBeNull()
    expect(first.signal.aborted).toBe(true)
    expect(second.signal.aborted).toBe(false)
    expect(activeStreamRequestId('sangsu')).toBe('kmsg-operation-2')
  })

  it('persists a concurrent assistant draft under its own operation provenance', () => {
    for (const [operationId, entryId] of [
      ['kmsg-operation-1', 'reply-1'],
      ['kmsg-operation-2', 'reply-2'],
    ] as const) {
      upsertTrackedKeeperChatOperation({
        operationId,
        keeperName: 'sangsu',
        message: operationId,
        submittedAt: 1,
      })
      appendThreadEntry('sangsu', {
        id: entryId,
        role: 'assistant',
        source: 'direct_assistant',
        label: 'sangsu',
        text: '',
        rawText: '',
        timestamp: null,
        deliveryProvenance: operationDeliveryProvenance(
          operationId,
          'terminal_assistant',
        ),
        delivery: 'streaming',
        streamState: 'thinking',
        details: null,
      })
    }

    applyKeeperStreamEvent('sangsu', 'reply-2', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'second operation' },
    })
    _flushPendingKeeperStreamDeltasForTests()

    const operations = trackedKeeperChatOperationsForKeeper('sangsu')
    expect(operations.find(item => item.operationId === 'kmsg-operation-1')?.assistantDraft)
      .toBeUndefined()
    expect(operations.find(item => item.operationId === 'kmsg-operation-2')?.assistantDraft?.traceSteps)
      .toEqual([{ kind: 'think', text: 'second operation', ts: expect.any(String) }])
  })

  it('accepts the singular operation SSE envelope and rejects the removed event type', () => {
    expect(parseSSEMessage({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ts_unix: 1,
      ag_ui_event: {
        type: 'TEXT_MESSAGE_CONTENT',
        threadId: 'keeper:sangsu',
        timestamp: 1,
        delta: 'hello',
      },
    })?.type).toBe('keeper_chat_operation_event')

    expect(parseSSEMessage({
      type: 'keeper_chat_turn_event',
      name: 'sangsu',
      ts_unix: 1,
      ag_ui_event: {},
    })).toBeNull()
  })
})


describe('applyKeeperStreamEvent tool calls', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
    _resetLiveSendRequestOwnersForTests()
  })

  it('streams a live tool-call entry above the assistant bubble', () => {
    assistantEntry('kmsg-tool-1')
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-1',
      toolCallName: 'masc_status',
    })).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(), toolCallId: 'tc-1', delta: '{"fast":' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(), toolCallId: 'tc-1', delta: 'true}' })

    const thread = keeperThreads.value.sangsu ?? []
    const toolIndex = thread.findIndex(entry => entry.toolCallId === 'tc-1')
    const replyIndex = thread.findIndex(entry => entry.id === 'reply-1')
    expect(toolIndex).toBeGreaterThanOrEqual(0)
    expect(toolIndex).toBeLessThan(replyIndex)

    const tool = thread[toolIndex]!
    expect(tool.role).toBe('tool')
    expect(tool.label).toBe('masc_status')
    expect(tool.text).toBe('{"fast":true}')
    expect(tool.delivery).toBe('streaming')
    expect(tool.deliveryProvenance).toEqual({
      delivery_key: { kind: 'operation', operation_id: 'kmsg-tool-1' },
      transcript_slot: { kind: 'tool_delivery', ordinal: 0 },
    })
    const reply = thread[replyIndex]!
    expect(reply.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_status',
        toolCallId: 'tc-1',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        status: 'pending',
        args: '{"fast":true}',
        ts: expect.any(String),
        agentCoreBlockIndex: 0,
      },
    ])

    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END',
      ...toolOccurrence(), toolCallId: 'tc-1' })
    const argsFinished = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-1')
    expect(argsFinished?.delivery).toBe('streaming')
    expect(argsFinished?.streamState).toBe('streaming')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-1', executionId: 'exec-tc-1' },
    })
    const finished = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-1')
    expect(finished?.delivery).toBe('delivered')
    expect(finished?.streamState).toBeNull()
    expect(finished?.executionId).toBe('exec-tc-1')
    expect(finished?.deliveryProvenance).toEqual({
      delivery_key: { kind: 'operation', operation_id: 'kmsg-tool-1' },
      transcript_slot: {
        kind: 'tool_call',
        execution_id: 'exec-tc-1',
        ordinal: 0,
      },
    })
  })

  it('preserves opaque provider tool-call ids throughout the live stream', () => {
    assistantEntry()
    const toolCallId = '  tc-opaque \t'
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId,
      toolCallName: 'masc_status',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId,
      delta: '{}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId,
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: toolCallId, executionId: 'exec-opaque' },
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.find(entry => entry.toolCallId === toolCallId)).toMatchObject({
      text: '{}',
      delivery: 'delivered',
    })
    expect(thread.find(entry => entry.id === 'reply-1')?.traceSteps).toEqual([
      expect.objectContaining({
        kind: 'tool',
        toolCallId,
        status: 'ok',
        args: '{}',
      }),
    ])
  })

  it('does not overwrite a settled canonical execution identity', () => {
    assistantEntry('kmsg-tool-conflict')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-conflict',
      toolCallName: 'Read',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-conflict', executionId: 'exec-first' },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-conflict', executionId: 'exec-second' },
    })).toBe('KEEPER_TOOL_RESULT_READY conflicts with the recorded execution_id')

    const tool = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-conflict')
    expect(tool?.executionId).toBe('exec-first')
    expect(tool?.deliveryProvenance?.transcript_slot).toEqual({
      kind: 'tool_call',
      execution_id: 'exec-first',
      ordinal: 0,
    })
  })

  it('keeps a ready tool delivered when the provider end arrives later', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-ready-first',
      toolCallName: 'masc_status',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-ready-first', executionId: 'exec-ready-first' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId: 'tc-ready-first',
    })

    const finished = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-ready-first')
    expect(finished?.delivery).toBe('delivered')
    expect(finished?.streamState).toBeNull()
  })

  it('replaces tool-call args when Agent Core emits argument snapshots', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-snapshot',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-snapshot',
      snapshot: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-snapshot',
      snapshot: '{"limit":2}',
    })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-snapshot')
    expect(tool?.text).toBe('{"limit":2}')
    expect(tool?.rawText).toBe('{"limit":2}')
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_board_list',
        toolCallId: 'tc-snapshot',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        status: 'pending',
        args: '{"limit":2}',
        ts: expect.any(String),
        agentCoreBlockIndex: 0,
      },
    ])
  })

  it('records tool calls in the assistant trace between thinking deltas', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'think A' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-ordered',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-ordered',
      delta: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId: 'tc-ordered',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-ordered', executionId: 'exec-ordered' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'think B' },
    })

    _flushPendingKeeperStreamDeltasForTests()
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      { kind: 'think', text: 'think A', ts: expect.any(String) },
      {
        kind: 'tool',
        name: 'masc_board_list',
        toolCallId: 'tc-ordered',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        executionId: 'exec-ordered',
        status: 'ok',
        args: '{"limit":1}',
        ts: expect.any(String),
        agentCoreBlockIndex: 0,
      },
      { kind: 'think', text: 'think B', ts: expect.any(String) },
    ])
  })

  it('promotes text followed by a tool call and keeps only terminal text as Chat', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_START',
      value: { index: 2, content_type: 'text' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '  PR 목록을 확인하겠다.\n',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_END' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-progress',
      toolCallName: 'Execute',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-progress',
      delta: '{"argv":["pr","list"]}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId: 'tc-progress',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-progress', executionId: 'exec-progress' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '최종 결과다.',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' })

    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.text).toBe('최종 결과다.')
    expect(reply?.rawText).toBe('최종 결과다.')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'progress',
        text: '  PR 목록을 확인하겠다.\n',
        ts: expect.any(String),
        agentCoreBlockIndex: 2,
      },
      {
        kind: 'tool',
        name: 'Execute',
        toolCallId: 'tc-progress',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        executionId: 'exec-progress',
        status: 'ok',
        args: '{"argv":["pr","list"]}',
        ts: expect.any(String),
        agentCoreBlockIndex: 0,
      },
    ])
  })

  it('keeps repeated intermediate rounds as progress when the run times out', () => {
    assistantEntry()
    for (const [index, text] of [
      [2, 'PR 목록을 확인하겠다.'],
      [4, 'cwd를 설정해서 다시 보겠다.'],
    ] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_CONTENT_BLOCK_START',
        value: { index, content_type: 'text' },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TEXT_MESSAGE_CONTENT',
        delta: text,
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(index),
        toolCallId: `tc-progress-${index}`,
        toolCallName: 'Execute',
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_END',
        ...toolOccurrence(index),
        toolCallId: `tc-progress-${index}`,
      })
    }

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'RUN_ERROR',
      message: 'request was cancelled by operator',
    })).toBe('request was cancelled by operator')

    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.text).toBe('')
    expect(reply?.rawText).toBe('')
    expect(reply?.traceSteps?.filter(step => step.kind === 'progress')).toEqual([
      expect.objectContaining({ kind: 'progress', text: 'PR 목록을 확인하겠다.', agentCoreBlockIndex: 2 }),
      expect.objectContaining({ kind: 'progress', text: 'cwd를 설정해서 다시 보겠다.', agentCoreBlockIndex: 4 }),
    ])
  })

  it('preserves Agent Core content block index on tool trace steps', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_START',
      value: {
        index: 7,
        content_type: 'tool_use',
        tool_call_id: 'tc-agentCore',
        tool_call_name: 'masc_board_list',
      },
    })
    let reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toBeUndefined()

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(7),
      toolCallId: 'tc-agentCore',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(7),
      toolCallId: 'tc-agentCore',
      delta: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(7),
      toolCallId: 'tc-agentCore',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(7), toolCallId: 'tc-agentCore', executionId: 'exec-agent-core' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_STOP',
      value: { index: 7 },
    })

    reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_board_list',
        toolCallId: 'tc-agentCore',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-7',
        executionId: 'exec-agent-core',
        status: 'ok',
        args: '{"limit":1}',
        ts: expect.any(String),
        agentCoreBlockIndex: 7,
      },
    ])
  })

  it('keeps a provider-correlated server protocol error on the assistant diagnostic', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_START',
      value: {
        index: 2,
        content_type: 'tool_use',
        tool_call_id: 'tc-first',
        tool_call_name: 'keeper_memory_search',
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(2),
      toolCallId: 'tc-first',
      toolCallName: 'keeper_memory_search',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_START',
      value: {
        index: 2,
        content_type: 'tool_use',
        tool_call_id: 'tc-second',
        tool_call_name: 'masc_board_list',
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_start_duplicate_index',
        index: 2,
        tool_call_id: 'tc-first',
        reason: 'tool-use block index already active',
      },
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.find(entry => entry.toolCallId === 'tc-second')).toBeUndefined()
    const tool = thread.find(entry => entry.toolCallId === 'tc-first')
    expect(tool?.delivery).toBe('streaming')
    expect(tool?.streamState).toBe('streaming')
    expect(tool?.error).toBeUndefined()
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'keeper_memory_search',
        toolCallId: 'tc-first',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-2',
        status: 'pending',
        ts: expect.any(String),
        agentCoreBlockIndex: 2,
      },
    ])
    expect(reply?.rawText).toContain('[stream protocol] tool_start_duplicate_index')
  })

  it('marks the exact occurrence instead of a provider-correlated sibling', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(0),
      toolCallId: 'tc-first',
      toolCallName: 'Read',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(1),
      toolCallId: 'tc-second',
      toolCallName: 'Write',
    })

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(1),
      toolCallId: 'tc-first',
      delta: '{}',
    })

    const tools = (keeperThreads.value.sangsu ?? []).filter(entry => entry.role === 'tool')
    const first = tools.find(entry => entry.toolCallId === 'tc-first')
    expect(first?.delivery).toBe('streaming')
    expect(first?.error).toBeUndefined()
    expect(tools.find(entry => entry.toolCallId === 'tc-second')).toMatchObject({
      delivery: 'error',
      error: 'TOOL_CALL_ARGS provider correlation conflicts with its server occurrence',
    })
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps?.filter(step => step.kind === 'tool').map(step => ({
      toolOccurrenceId: step.toolOccurrenceId,
      status: step.status,
      agentCoreBlockIndex: step.agentCoreBlockIndex,
    }))).toEqual([
      {
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        status: 'pending',
        agentCoreBlockIndex: 0,
      },
      {
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-1',
        status: 'err',
        agentCoreBlockIndex: 1,
      },
    ])
  })

  it('keeps a protocol error without quarantine occurrence assistant-only', () => {
    assistantEntry()
    for (const [blockIndex, toolCallName] of [[0, 'Read'], [1, 'Write']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(blockIndex),
        toolCallId: 'tc-duplicate-error',
        toolCallName,
      })
    }

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        index: 1,
        tool_call_id: 'tc-duplicate-error',
        reason: 'provider correlation is ambiguous',
      },
    })

    const thread = keeperThreads.value.sangsu ?? []
    const tools = thread.filter(entry => entry.toolCallId === 'tc-duplicate-error')
    expect(tools.map(entry => entry.delivery)).toEqual(['streaming', 'streaming'])
    expect(tools.map(entry => entry.error)).toEqual([undefined, undefined])
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.error).toBe(
      'tool_args_without_start | index=1 | tool_call_id=tc-duplicate-error | provider correlation is ambiguous',
    )
    expect(reply?.traceSteps?.filter(step => step.kind === 'tool').map(step => ({
      status: step.status,
      agentCoreBlockIndex: step.agentCoreBlockIndex,
    }))).toEqual([
      { status: 'pending', agentCoreBlockIndex: 0 },
      { status: 'pending', agentCoreBlockIndex: 1 },
    ])
  })

  it('keeps QUARANTINE then RESULT failed on the exact duplicate-provider occurrence', () => {
    assistantEntry()
    for (const [blockIndex, toolCallName] of [[0, 'Read'], [1, 'Write']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(blockIndex),
        toolCallId: 'tc-quarantined-duplicate',
        toolCallName,
      })
    }

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        index: 1,
        tool_call_id: 'tc-quarantined-duplicate',
        reason: 'exact occurrence quarantined',
        quarantined_occurrence: {
          ...toolOccurrence(1),
          providerMessageId: 'provider-message-1',
        },
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(1),
      toolCallId: 'tc-quarantined-duplicate',
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: {
        ...toolOccurrence(1),
        toolCallId: 'tc-quarantined-duplicate',
        executionId: 'exec-quarantined-after',
      },
    })).toBe('KEEPER_TOOL_RESULT_READY targets a quarantined tool occurrence')

    const thread = keeperThreads.value.sangsu ?? []
    const tools = thread.filter(entry => entry.toolCallId === 'tc-quarantined-duplicate')
    expect(tools.map(entry => entry.delivery)).toEqual(['streaming', 'error'])
    expect(tools.map(entry => entry.executionId)).toEqual([undefined, undefined])
    expect(tools.map(entry => entry.error)).toEqual([
      undefined,
      'tool_args_without_start | index=1 | tool_call_id=tc-quarantined-duplicate | exact occurrence quarantined',
    ])
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps?.filter(step => step.kind === 'tool').map(step => ({
      status: step.status,
      agentCoreBlockIndex: step.agentCoreBlockIndex,
    }))).toEqual([
      { status: 'pending', agentCoreBlockIndex: 0 },
      { status: 'err', agentCoreBlockIndex: 1 },
    ])
  })

  it('freezes an exact quarantined occurrence against later args', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-quarantine-args',
      toolCallName: 'Read',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-quarantine-args',
      snapshot: '{"path":"before.ml"}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_replay_mismatch',
        reason: 'exact occurrence quarantined',
        quarantined_occurrence: toolOccurrence(),
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(),
      toolCallId: 'tc-quarantine-args',
      snapshot: '{"path":"after.ml"}',
    })

    const thread = keeperThreads.value.sangsu ?? []
    const tool = thread.find(entry => entry.toolCallId === 'tc-quarantine-args')
    expect(tool).toMatchObject({
      text: '{"path":"before.ml"}',
      rawText: '{"path":"before.ml"}',
      toolCallEnded: true,
      delivery: 'error',
      error: 'tool_replay_mismatch | exact occurrence quarantined',
    })
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps?.find(step => step.kind === 'tool')).toMatchObject({
      args: '{"path":"before.ml"}',
      status: 'err',
    })
  })

  it('keeps RESULT then QUARANTINE failed and tombstoned for later result replay', () => {
    assistantEntry()
    for (const [blockIndex, toolCallName] of [[0, 'Read'], [1, 'Write']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(blockIndex),
        toolCallId: 'tc-result-before-quarantine',
        toolCallName,
      })
    }
    const result = {
      type: 'CUSTOM' as const,
      name: 'KEEPER_TOOL_RESULT_READY' as const,
      value: {
        ...toolOccurrence(1),
        toolCallId: 'tc-result-before-quarantine',
        executionId: 'exec-result-before-quarantine',
      },
    }
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', result)).toBeNull()

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        index: 1,
        tool_call_id: 'tc-result-before-quarantine',
        reason: 'late exact occurrence quarantine',
        quarantined_occurrence: {
          ...toolOccurrence(1),
          providerMessageId: 'provider-message-1',
        },
      },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', result)).toBe(
      'KEEPER_TOOL_RESULT_READY targets a quarantined tool occurrence',
    )

    const thread = keeperThreads.value.sangsu ?? []
    const tools = thread.filter(entry => entry.toolCallId === 'tc-result-before-quarantine')
    expect(tools.map(entry => entry.delivery)).toEqual(['streaming', 'error'])
    expect(tools.map(entry => entry.executionId)).toEqual([
      undefined,
      'exec-result-before-quarantine',
    ])
    expect(tools.map(entry => entry.error)).toEqual([
      undefined,
      'tool_args_without_start | index=1 | tool_call_id=tc-result-before-quarantine | late exact occurrence quarantine',
    ])
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps?.filter(step => step.kind === 'tool').map(step => ({
      executionId: step.executionId,
      status: step.status,
      agentCoreBlockIndex: step.agentCoreBlockIndex,
    }))).toEqual([
      { executionId: undefined, status: 'pending', agentCoreBlockIndex: 0 },
      {
        executionId: 'exec-result-before-quarantine',
        status: 'err',
        agentCoreBlockIndex: 1,
      },
    ])
  })

  it('does not let a quarantine for an unopened occurrence poison a later tool', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        reason: 'no row existed yet',
        quarantined_occurrence: toolOccurrence(0),
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(0),
      toolCallId: 'tc-after-unopened-quarantine',
      toolCallName: 'Read',
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: {
        ...toolOccurrence(0),
        toolCallId: 'tc-after-unopened-quarantine',
        executionId: 'exec-after-unopened-quarantine',
      },
    })).toBeNull()

    const tool = keeperThreads.value.sangsu?.find(
      entry => entry.toolCallId === 'tc-after-unopened-quarantine',
    )
    expect(tool?.delivery).toBe('delivered')
    expect(tool?.executionId).toBe('exec-after-unopened-quarantine')
  })

  it('routes providerless tool events by server occurrence', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-no-fallback',
      toolCallName: 'masc_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(), delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
    })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.toolCallId === 'tc-no-fallback')
    expect(tool?.text).toBe('{"post_id":"p-1"}')
    expect(tool?.delivery).toBe('streaming')
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.error).toBeUndefined()
  })

  it('records server stream protocol errors on the assistant entry', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        index: 2,
        reason: 'tool argument delta arrived before tool start',
      },
    })

    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.error).toBe(
      'tool_args_without_start | index=2 | tool argument delta arrived before tool start',
    )
    expect(reply?.rawText).toContain('[stream protocol] tool_args_without_start')
  })

  it('keeps a later occurrence when a provider id is reused', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-repeat',
      toolCallName: 'masc_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(), toolCallId: 'tc-repeat', delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END',
      ...toolOccurrence(), toolCallId: 'tc-repeat' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-repeat', executionId: 'exec-repeat' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(1),
      toolCallId: 'tc-repeat',
      toolCallName: 'masc_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END',
      ...toolOccurrence(1), toolCallId: 'tc-repeat' })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'tc-repeat', executionId: 'exec-repeat' },
    })).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(1), toolCallId: 'tc-repeat', executionId: 'exec-repeat-2' },
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.filter(entry => entry.toolCallId === 'tc-repeat')).toHaveLength(2)
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_board_post',
        toolCallId: 'tc-repeat',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-0',
        executionId: 'exec-repeat',
        status: 'ok',
        args: '{"post_id":"p-1"}',
        ts: expect.any(String),
        agentCoreBlockIndex: 0,
      },
      {
        kind: 'tool',
        name: 'masc_board_post',
        toolCallId: 'tc-repeat',
        toolOccurrenceId: 'tool-delivery-reply-1-stream-0-block-1',
        executionId: 'exec-repeat-2',
        status: 'ok',
        ts: expect.any(String),
        agentCoreBlockIndex: 1,
      },
    ])
  })

  it('joins same-message duplicate provider ids by server occurrence', () => {
    assistantEntry()
    for (const [blockIndex, toolCallName] of [[0, 'Read'], [1, 'Write']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(blockIndex),
        toolCallId: 'tc-ambiguous',
        toolCallName,
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_END',
        ...toolOccurrence(blockIndex),
        toolCallId: 'tc-ambiguous',
      })
    }
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(1), toolCallId: 'tc-ambiguous', executionId: 'exec-write' },
    })).toBeNull()

    const tools = (keeperThreads.value.sangsu ?? [])
      .filter(entry => entry.toolCallId === 'tc-ambiguous')
    expect(tools).toHaveLength(2)
    expect(tools.map(entry => entry.executionId ?? null)).toEqual([null, 'exec-write'])
  })

  it('keeps parallel duplicate provider occurrences distinct by content block', () => {
    assistantEntry()
    for (const [index, toolCallName] of [[3, 'Read'], [5, 'Write']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_CONTENT_BLOCK_START',
        value: {
          index,
          content_type: 'tool_use',
          tool_call_id: 'tc-parallel-duplicate',
          tool_call_name: toolCallName,
        },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_START',
        ...toolOccurrence(index),
        toolCallId: 'tc-parallel-duplicate',
        toolCallName,
      })
    }

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      ...toolOccurrence(5),
      toolCallId: 'tc-parallel-duplicate',
      delta: '{}',
    })

    const thread = keeperThreads.value.sangsu ?? []
    const tools = thread.filter(entry => entry.toolCallId === 'tc-parallel-duplicate')
    expect(tools).toHaveLength(2)
    expect(tools.map(entry => entry.id)).toEqual([
      'tool-delivery-reply-1-stream-0-block-3',
      'tool-delivery-reply-1-stream-0-block-5',
    ])
    expect(tools.map(entry => entry.delivery)).toEqual(['streaming', 'streaming'])
    expect(tools.map(entry => entry.text)).toEqual(['', '{}'])
    expect(thread.find(entry => entry.id === 'reply-1')?.error).toBeUndefined()
  })

  it('treats an exact repeated provider end as idempotent', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      ...toolOccurrence(),
      toolCallId: 'tc-end-replay',
      toolCallName: 'Read',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId: 'tc-end-replay',
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      ...toolOccurrence(),
      toolCallId: 'tc-end-replay',
    })).toBeNull()

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.filter(entry => entry.toolCallId === 'tc-end-replay')).toHaveLength(1)
    expect(thread.find(entry => entry.id === 'reply-1')?.error).toBeNull()
  })
})
