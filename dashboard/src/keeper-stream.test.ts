import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  _resetLiveSendRequestOwnersForTests,
  activeStreamRequestId,
  appendThreadEntry,
  setActiveStream,
  setActiveStreamRequestId,
} from './keeper-state'
import { keeperThreads } from './keeper-state'
import {
  KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS,
  _flushPendingKeeperStreamDeltasForTests,
  _resetKeeperStreamBuffersForTests,
  abortKeeperThreadMessage,
  applyKeeperQueuedTurnEvent,
  applyKeeperStreamEvent,
} from './keeper-stream'
import { STREAMING_THINKING_PREVIEW_CHARS } from './config/constants'
import type { KeeperChatStreamEvent } from './api'
import { parseSSEMessage } from './schemas/sse'
import { isRecord } from './lib/type-guards'

function assistantEntry(): void {
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
    details: null,
  })
}

describe('applyKeeperStreamEvent', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
    _resetLiveSendRequestOwnersForTests()
  })

  it('appends content for TEXT_MESSAGE_CONTENT', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '안녕',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('안녕')
    expect(entry?.delivery).toBe('streaming')
    expect(entry?.streamState).toBe('streaming')
    expect(entry?.streamContract?.deliveryReceipt).toBe('client_observed_sse_event')
  })

  it('ignores empty delta text events', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
  })

  it('marks the assistant entry queued when the server accepts a request', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_QUEUE_REQUEST',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'queued',
        modalities: ['text'],
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBe('opening')
    expect(entry?.streamContract?.deliveryReceipt).toBe('client_observed_sse_event')
  })

  it('retains the durable receipt when a busy chat message enters the server queue', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_QUEUED',
      value: {
        keeper_name: 'sangsu',
        status: 'queued',
        receipt_id: 'chatq_00000000-0000-4000-8000-000000000007',
        queue_revision: '12',
        pending_count: 3,
        inflight_count: 1,
        recovery_required_count: 1,
        shutdown_operation_id: ' shutdown-op-7 ',
        in_flight_lane: 'autonomous',
        in_flight_started_at: 42,
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBeNull()
    expect(entry?.details).toMatchObject({
      queueReceiptId: 'chatq_00000000-0000-4000-8000-000000000007',
      queueShutdownOperationId: 'shutdown-op-7',
      queueRevision: '12',
      queuePendingCount: 3,
      queueInflightCount: 1,
      queueRecoveryRequiredCount: 1,
      queueInFlightLane: 'autonomous',
      queueInFlightStartedAt: 42,
    })
    expect(entry?.text).toBe(
      'sangsu의 이전 메시지 상태를 확인해야 해요. 새 메시지는 안전하게 대기 중입니다.',
    )
    expect(entry?.streamContract).toMatchObject({
      source: 'queue_event',
      eventName: 'KEEPER_CHAT_QUEUED',
      deliveryReceipt: 'client_observed_sse_event',
    })
  })

  it('rejects a busy queue acceptance event without a durable receipt', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_QUEUED',
      value: {
        status: 'queued',
        pending_count: 1,
        inflight_count: 0,
        recovery_required_count: 0,
        shutdown_operation_id: null,
      },
    })).toBe('Keeper queue acceptance is missing its durable receipt metadata.')
  })

  it('rejects malformed or partial durable queue acceptance metadata', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_QUEUED',
      value: {
        receipt_id: 'not-a-chat-receipt',
        queue_revision: '1',
        pending_count: 1,
        inflight_count: 0,
        recovery_required_count: 0,
        shutdown_operation_id: null,
      },
    })).toBe('Keeper queue acceptance is missing its durable receipt metadata.')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_QUEUED',
      value: {
        receipt_id: 'chatq_00000000-0000-4000-8000-000000000007',
        pending_count: 1,
        inflight_count: 0,
        recovery_required_count: 0,
        shutdown_operation_id: null,
      },
    })).toBe('Keeper queue acceptance is missing its durable receipt metadata.')
  })

  it('rejects queue acceptance that omits recovery-required depth', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_QUEUED',
      value: {
        receipt_id: 'chatq_00000000-0000-4000-8000-000000000007',
        queue_revision: '1',
        pending_count: 1,
        inflight_count: 0,
        shutdown_operation_id: null,
      },
    })).toBe('Keeper queue acceptance is missing its durable receipt metadata.')
  })

  it('rejects missing, blank, or wrongly typed shutdown operation metadata', () => {
    assistantEntry()
    const baseValue = {
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000007',
      queue_revision: '1',
      pending_count: 1,
      inflight_count: 0,
      recovery_required_count: 0,
    }

    for (const shutdownOperationId of [undefined, '   ', 7]) {
      const value = shutdownOperationId === undefined
        ? baseValue
        : { ...baseValue, shutdown_operation_id: shutdownOperationId }
      expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_CHAT_QUEUED',
        value,
      } as unknown as KeeperChatStreamEvent)).toBe('Keeper queue acceptance has invalid shutdown operation metadata.')
    }
  })

  it('surfaces failed request terminal events before stream error close', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'error',
        ok: false,
        message: 'Timeout after 630.0s',
      },
    })).toBe('Timeout after 630.0s')

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('error')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBe('Timeout after 630.0s')
    expect(entry?.text).toBe('Keeper request failed: Timeout after 630.0s')
    expect(entry?.streamContract?.deliveryReceipt).toBe('client_observed_sse_event')
  })

  it('renders cancelled request terminal events without an error bubble', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'cancelled',
        ok: false,
        message: 'keeper chat stream cancelled by client',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('cancelled')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBeNull()
    expect(entry?.text).toBe('요청이 취소되었습니다.')
    expect(entry?.streamContract?.deliveryReceipt).toBe('client_observed_sse_event')
  })

  it('finalizes successful request terminal events after streamed thinking', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'checking state' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: '완료했습니다.',
        turn_outcome: 'visible_reply',
        turn_ref: 'trace-current#1',
      },
    })

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'done',
        ok: true,
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_END',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('완료했습니다.')
    expect(entry?.delivery).toBe('delivered')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBeNull()
    expect(entry?.streamContract?.deliveryReceipt).toBe('client_observed_sse_event')
    expect(activeStreamRequestId('sangsu')).toBeNull()
  })

  it('finalizes queued visible replies when a successful terminal follows reply details', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_QUEUE_REQUEST',
      value: {
        request_id: 'kmsg_current',
        status: 'queued',
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: '큐에서 완료했습니다.',
        turn_outcome: 'visible_reply',
        turn_ref: 'trace-current#2',
      },
    })

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'done',
        ok: true,
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_END',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('큐에서 완료했습니다.')
    expect(entry?.delivery).toBe('delivered')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBeNull()
    expect(activeStreamRequestId('sangsu')).toBeNull()
  })

  it('projects explicit continuation checkpoints as a durable status', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTINUATION_CHECKPOINT',
      value: {
        message: 'Continuation checkpoint saved; keeper remains scheduled.',
      },
    })

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'done',
        ok: true,
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_END',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.delivery).toBe('delivered')
    expect(entry?.streamState).toBeNull()
    expect(entry?.details?.turnOutcome).toBe('continuation_checkpoint')
    expect(entry?.blocks).toEqual([
      { t: 'status', kind: 'continuation_checkpoint' },
    ])
    expect(activeStreamRequestId('sangsu')).toBeNull()
  })

  it('finalizes a connector-delivered turn as a terminal status, not a hang', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'posted the answer to #ops on Slack',
        turn_outcome: 'external_effect_completed',
        turn_ref: 'trace-current#3',
      },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_EXTERNAL_EFFECT_COMPLETED',
      value: null,
    })).toBeNull()

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'done',
        ok: true,
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_END',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('posted the answer to #ops on Slack')
    expect(entry?.delivery).toBe('delivered')
    expect(entry?.streamState).toBeNull()
    expect(entry?.details?.turnOutcome).toBe('external_effect_completed')
    expect(activeStreamRequestId('sangsu')).toBeNull()
  })

  it('does not leave successful terminal events in a live thinking state without reply details', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'checking state' },
    })

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'done',
        ok: true,
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_END',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('delivered')
    expect(entry?.streamState).toBeNull()
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'checking state', ts: expect.any(String) },
    ])
    expect(activeStreamRequestId('sangsu')).toBeNull()
  })

  it('ignores terminal events for a different active request id', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_stale',
        status: 'cancelled',
        ok: false,
        message: 'stale terminal',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
  })

  it('ignores no-id terminal events while a request id is active', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        status: 'cancelled',
        ok: false,
        message: 'legacy terminal without request id',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
    expect(activeStreamRequestId('sangsu')).toBe('kmsg_current')
  })

  it('surfaces an invalid request terminal status', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'running',
        ok: false,
        message: 'not terminal yet',
      },
    } as unknown as KeeperChatStreamEvent)).toBe('Keeper request terminal event has invalid status.')

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
  })

  // RFC-0232 P2: the checkpoint distinction rides the producer-typed
  // `turn_outcome` field, not the reply text.
  it('does not render a declared continuation checkpoint as a chat reply', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
        turn_outcome: 'continuation_checkpoint',
        turn_ref: 'trace-checkpoint#1',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('Continuation checkpoint saved; keeper remains scheduled for the next cycle.')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBeNull()
  })

  it('renders checkpoint-shaped text as a reply when not declared a checkpoint', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
        turn_outcome: 'visible_reply',
        turn_ref: 'trace-visible#1',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('Continuation checkpoint saved; keeper remains scheduled for the next cycle.')
    expect(entry?.delivery).toBe('sending')
  })

  it('keeps the producer turnRef from reply details for history rehydrate joins', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'done',
        turn_outcome: 'visible_reply',
        turn_ref: 'trace-live#42',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.turnRef).toBe('trace-live#42')
    expect(entry?.details?.turnRef).toBe('trace-live#42')
  })

  it('keeps OAS stream message metadata through reply details', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_START',
      value: {
        provider_message_id: 'msg-oas-1',
        model: 'gpt-5.5',
        usage: {
          input_tokens: 10,
          output_tokens: 1,
          total_tokens: 11,
        },
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_DELTA',
      value: {
        stop_reason: 'end_turn',
        usage: {
          input_tokens: 10,
          output_tokens: 2,
          total_tokens: 12,
          cache_creation_input_tokens: 3,
          cache_read_input_tokens: 4,
          cost_usd: 0.125,
        },
      },
    })).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'done',
        turn_outcome: 'visible_reply',
        turn_ref: 'trace-live#43',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('done')
    expect(entry?.turnRef).toBe('trace-live#43')
    expect(entry?.details?.providerMessageId).toBe('msg-oas-1')
    expect(entry?.details?.modelUsed).toBe('gpt-5.5')
    expect(entry?.details?.stopReason).toBe('end_turn')
    expect(entry?.details?.costUsd).toBe(0.125)
    expect(entry?.details?.usage).toEqual({
      inputTokens: 10,
      outputTokens: 2,
      totalTokens: 12,
      cacheCreationInputTokens: 3,
      cacheReadInputTokens: 4,
      costUsd: 0.125,
    })
  })

  it('suppresses a declared checkpoint regardless of reply text', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: '작업을 완료했습니다.',
        turn_outcome: 'continuation_checkpoint',
        turn_ref: 'trace-checkpoint#2',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.delivery).toBe('queued')
  })

  it('suppresses a declared no-visible reply without marking it queued', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'hidden runtime-only observation',
        turn_outcome: 'no_visible_reply',
        turn_ref: 'trace-no-visible#1',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('hidden runtime-only observation')
    expect(entry?.delivery).toBe('no_reply')
    expect(entry?.streamState).toBeNull()
  })

  it('extracts error messages from events', () => {
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'RUN_ERROR',
      message: 'boom',
    })).toBe('boom')
  })

  it('sets thinking state on KEEPER_THINKING_DELTA', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'reasoning about the problem...' },
    })).toBeNull()

    _flushPendingKeeperStreamDeltasForTests()
    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.streamState).toBe('thinking')
    expect(entry?.delivery).toBe('streaming')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'reasoning about the problem...', ts: expect.any(String) },
    ])
  })

  it('appends multiple thinking deltas to one trace step', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'checking ' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'tools' },
    })

    expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')?.traceSteps).toBeUndefined()
    _flushPendingKeeperStreamDeltasForTests()
    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'checking tools', ts: expect.any(String) },
    ])
  })

  it('coalesces live thinking deltas until the thinking flush interval expires', async () => {
    vi.useFakeTimers()
    try {
      assistantEntry()
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { delta: 'checking ' },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { delta: 'tool evidence' },
      })

      expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')?.traceSteps).toBeUndefined()

      await vi.advanceTimersByTimeAsync(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS - 1)
      expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')?.traceSteps).toBeUndefined()

      await vi.advanceTimersByTimeAsync(1)
      const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
      expect(entry?.traceSteps).toEqual([
        { kind: 'think', text: 'checking tool evidence', ts: expect.any(String) },
      ])
    } finally {
      vi.useRealTimers()
    }
  })

  it('keeps live thinking state bounded until a phase boundary commits the full text', async () => {
    vi.useFakeTimers()
    try {
      const hiddenHead = 'hidden-head-marker'
      const visibleTail = 'visible-tail-marker'
      assistantEntry()

      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { delta: `${hiddenHead} ${'x'.repeat(STREAMING_THINKING_PREVIEW_CHARS + 200)} ` },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { delta: visibleTail },
      })

      await vi.advanceTimersByTimeAsync(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)

      const liveEntry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
      const liveThinking = liveEntry?.traceSteps?.[0]
      if (!liveThinking || liveThinking.kind !== 'think') {
        throw new Error('expected live thinking trace step')
      }
      expect(liveThinking.text).toContain(visibleTail)
      expect(liveThinking.text).not.toContain(hiddenHead)
      expect(liveThinking.text.length).toBeLessThanOrEqual(STREAMING_THINKING_PREVIEW_CHARS)

      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START' })

      const committedEntry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
      const committedThinking = committedEntry?.traceSteps?.[0]
      if (!committedThinking || committedThinking.kind !== 'think') {
        throw new Error('expected committed thinking trace step')
      }
      expect(committedThinking.text).toContain(hiddenHead)
      expect(committedThinking.text).toContain(visibleTail)
      expect(committedThinking.text.length).toBeGreaterThan(STREAMING_THINKING_PREVIEW_CHARS)
    } finally {
      vi.useRealTimers()
    }
  })

  it('flushes pending thinking deltas at TEXT_MESSAGE_START without reverting stream state', () => {
    assistantEntry()
    // Thinking delta schedules a pending flush.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'thinking before text' },
    })
    // Text phase begins before the scheduled flush runs.
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: 'hello',
    })
    // A still-scheduled flush must be a no-op: START already flushed it, so it
    // cannot revert streamState to 'thinking' after text streaming began.
    _flushPendingKeeperStreamDeltasForTests()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.streamState).toBe('streaming')
    expect(entry?.text).toBe('hello')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'thinking before text', ts: expect.any(String) },
    ])
  })

  it('preserves received thinking deltas when aborting a live stream', () => {
    assistantEntry()
    setActiveStream('sangsu', 'reply-1', new AbortController())
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'half-written reasoning' },
    })

    abortKeeperThreadMessage('sangsu')
    _flushPendingKeeperStreamDeltasForTests()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('cancelled')
    expect(entry?.streamState).toBeNull()
    expect(entry?.text).toBe('요청이 취소되었습니다.')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'half-written reasoning', ts: expect.any(String) },
    ])
  })

  it('splits thinking trace steps by OAS content block index', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 1, delta: 'checking ' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 1, delta: 'tools' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 2, delta: 'next block' },
    })

    _flushPendingKeeperStreamDeltasForTests()
    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'checking tools', ts: expect.any(String), oasBlockIndex: 1 },
      { kind: 'think', text: 'next block', ts: expect.any(String), oasBlockIndex: 2 },
    ])
  })
})

describe('applyKeeperQueuedTurnEvent', () => {
  const firstReceipt = 'chatq_00000000-0000-4000-8000-000000000001'
  const secondReceipt = 'chatq_00000000-0000-4000-8000-000000000002'

  beforeEach(() => {
    keeperThreads.value = {}
    _resetKeeperStreamBuffersForTests()
  })

  function queuedEntry(id: string, receiptId: string, text: string): void {
    appendThreadEntry('sangsu', {
      id,
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text,
      rawText: text,
      timestamp: null,
      delivery: 'queued',
      streamState: null,
      queueReceiptIds: [receiptId],
      details: { queueReceiptId: receiptId, queueState: 'pending' },
    })
  }

  it('streams thinking, tool args, and reply text into the exact queued bubble', () => {
    queuedEntry('first', firstReceipt, 'queued first')
    queuedEntry('second', secondReceipt, 'queued second')

    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'RUN_STARTED', runId: 'run-1' },
    })
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: '검토 중' },
      },
    })
    _flushPendingKeeperStreamDeltasForTests()
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TOOL_CALL_START', toolCallId: 'tc-1', toolCallName: 'Grep' },
    })
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-1', delta: '{"pattern":"x"}' },
    })
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TOOL_CALL_END', toolCallId: 'tc-1' },
    })
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TEXT_MESSAGE_START', messageId: 'message-1' },
    })
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TEXT_MESSAGE_CONTENT', messageId: 'message-1', delta: '완료했습니다.' },
    })

    const first = keeperThreads.value.sangsu?.find(entry => entry.id === 'first')
    const second = keeperThreads.value.sangsu?.find(entry => entry.id === 'second')
    expect(first?.text).toBe('완료했습니다.')
    expect(first?.details?.queueState).toBe('inflight')
    expect(first?.traceSteps).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: 'think', text: '검토 중' }),
      expect.objectContaining({
        kind: 'tool',
        toolCallId: 'tc-1',
        name: 'Grep',
        args: '{"pattern":"x"}',
        status: 'ok',
      }),
    ]))
    expect(second?.text).toBe('queued second')
    expect(second?.delivery).toBe('queued')
  })

  it('creates a receipt-keyed bubble for a browser that joins mid-turn', () => {
    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: '중간부터 표시' },
    })

    const entry = keeperThreads.value.sangsu?.[0]
    expect(entry?.id).toBe(`queued-turn-${firstReceipt}`)
    expect(entry?.queueReceiptIds).toEqual([firstReceipt])
    expect(entry?.text).toBe('중간부터 표시')
  })

  it.each([
    ['terminal', { name: 'KEEPER_REQUEST_TERMINAL', value: { status: 'done', ok: true } }],
    ['reply', { name: 'KEEPER_REPLY_DETAILS', value: { reply: 'done', turn_outcome: 'visible_reply' } }],
    ['queue', { name: 'KEEPER_CHAT_QUEUED', value: { status: 'queued' } }],
  ])('terminalizes malformed %s payloads after schema projection', (_label, custom) => {
    queuedEntry('first', firstReceipt, 'queued first')
    const parsed = parseSSEMessage({
      type: 'keeper_chat_turn_event',
      name: 'sangsu',
      receipt_id: firstReceipt,
      ts_unix: 1_712_000_000,
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        timestamp: 1_712_000_000,
        ...custom,
      },
    })
    const projected = parsed && isRecord(parsed.ag_ui_event)
      ? parsed.ag_ui_event
      : null
    expect(projected?.type).toBe('RUN_ERROR')

    const error = applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: projected as unknown as KeeperChatStreamEvent,
    })
    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'first')
    expect(error).toContain('Keeper stream protocol error')
    expect(entry?.delivery).toBe('error')
    expect(entry?.streamState).toBeNull()
  })

  it('does not reopen a terminal history row when a delayed event arrives', () => {
    queuedEntry('terminal', firstReceipt, '완료된 답변')
    const entries = keeperThreads.value.sangsu ?? []
    keeperThreads.value = {
      sangsu: entries.map(entry => ({
        ...entry,
        delivery: 'history' as const,
        streamState: null,
        details: { ...(entry.details ?? {}), queueState: 'delivered' as const },
      })),
    }

    applyKeeperQueuedTurnEvent('sangsu', {
      receiptId: firstReceipt,
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: '늦은 델타' },
    })

    expect(keeperThreads.value.sangsu?.[0]?.text).toBe('완료된 답변')
    expect(keeperThreads.value.sangsu?.[0]?.delivery).toBe('history')
  })
})

describe('applyKeeperStreamEvent tool calls', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
    _resetLiveSendRequestOwnersForTests()
  })

  it('streams a live tool-call entry above the assistant bubble', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-1',
      toolCallName: 'masc_status',
    })).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-1', delta: '{"fast":' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-1', delta: 'true}' })

    const thread = keeperThreads.value.sangsu ?? []
    const toolIndex = thread.findIndex(entry => entry.id === 'tool-tc-1')
    const replyIndex = thread.findIndex(entry => entry.id === 'reply-1')
    expect(toolIndex).toBeGreaterThanOrEqual(0)
    expect(toolIndex).toBeLessThan(replyIndex)

    const tool = thread[toolIndex]!
    expect(tool.role).toBe('tool')
    expect(tool.label).toBe('masc_status')
    expect(tool.text).toBe('{"fast":true}')
    expect(tool.delivery).toBe('streaming')
    const reply = thread[replyIndex]!
    expect(reply.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_status',
        toolCallId: 'tc-1',
        status: 'pending',
        args: '{"fast":true}',
        ts: expect.any(String),
      },
    ])

    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END', toolCallId: 'tc-1' })
    const finished = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-tc-1')
    expect(finished?.delivery).toBe('delivered')
    expect(finished?.streamState).toBeNull()
  })

  it('preserves opaque provider tool-call ids throughout the live stream', () => {
    assistantEntry()
    const toolCallId = '  tc-opaque \t'
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId,
      toolCallName: 'masc_status',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId,
      delta: '{}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      toolCallId,
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.find(entry => entry.id === `tool-${toolCallId}`)).toMatchObject({
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

  it('replaces tool-call args when OAS emits argument snapshots', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-snapshot',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-snapshot',
      snapshot: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-snapshot',
      snapshot: '{"limit":2}',
    })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-tc-snapshot')
    expect(tool?.text).toBe('{"limit":2}')
    expect(tool?.rawText).toBe('{"limit":2}')
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_board_list',
        toolCallId: 'tc-snapshot',
        status: 'pending',
        args: '{"limit":2}',
        ts: expect.any(String),
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
      toolCallId: 'tc-ordered',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-ordered',
      delta: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      toolCallId: 'tc-ordered',
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
        status: 'ok',
        args: '{"limit":1}',
        ts: expect.any(String),
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
      toolCallId: 'tc-progress',
      toolCallName: 'Execute',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-progress',
      delta: '{"argv":["pr","list"]}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      toolCallId: 'tc-progress',
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
        oasBlockIndex: 2,
      },
      {
        kind: 'tool',
        name: 'Execute',
        toolCallId: 'tc-progress',
        status: 'ok',
        args: '{"argv":["pr","list"]}',
        ts: expect.any(String),
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
        toolCallId: `tc-progress-${index}`,
        toolCallName: 'Execute',
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TOOL_CALL_END',
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
      expect.objectContaining({ kind: 'progress', text: 'PR 목록을 확인하겠다.', oasBlockIndex: 2 }),
      expect.objectContaining({ kind: 'progress', text: 'cwd를 설정해서 다시 보겠다.', oasBlockIndex: 4 }),
    ])
  })

  it('preserves OAS content block index on tool trace steps', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_START',
      value: {
        index: 7,
        content_type: 'tool_use',
        tool_call_id: 'tc-oas',
        tool_call_name: 'masc_board_list',
      },
    })
    let reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toBeUndefined()

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-oas',
      toolCallName: 'masc_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-oas',
      delta: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      toolCallId: 'tc-oas',
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
        toolCallId: 'tc-oas',
        status: 'ok',
        args: '{"limit":1}',
        ts: expect.any(String),
        oasBlockIndex: 7,
      },
    ])
  })

  it('marks the active tool errored when a server protocol error carries tool_call_id', () => {
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
    expect(thread.find(entry => entry.id === 'tool-tc-second')).toBeUndefined()
    const tool = thread.find(entry => entry.id === 'tool-tc-first')
    expect(tool?.delivery).toBe('error')
    expect(tool?.streamState).toBeNull()
    expect(tool?.error).toBe(
      'tool_start_duplicate_index | index=2 | tool_call_id=tc-first | tool-use block index already active',
    )
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'keeper_memory_search',
        toolCallId: 'tc-first',
        status: 'err',
        ts: expect.any(String),
        oasBlockIndex: 2,
      },
    ])
    expect(reply?.rawText).toContain('[stream protocol] tool_start_duplicate_index')
  })

  it('records a protocol error instead of guessing the tool when toolCallId is missing', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-no-fallback',
      toolCallName: 'masc_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END' })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-tc-no-fallback')
    expect(tool?.text).toBe('')
    expect(tool?.delivery).toBe('streaming')
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.rawText).toContain('[stream protocol] TOOL_CALL_ARGS missing toolCallId')
    expect(reply?.rawText).toContain('[stream protocol] TOOL_CALL_END missing toolCallId')
    expect(reply?.error).toBe('TOOL_CALL_END missing toolCallId')
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

  it('keeps duplicate TOOL_CALL_START events idempotent', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-repeat',
      toolCallName: 'masc_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-repeat', delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END', toolCallId: 'tc-repeat' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-repeat',
      toolCallName: 'masc_board_post',
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.filter(entry => entry.id === 'tool-tc-repeat')).toHaveLength(1)
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_board_post',
        toolCallId: 'tc-repeat',
        status: 'ok',
        args: '{"post_id":"p-1"}',
        ts: expect.any(String),
      },
    ])
  })
})
