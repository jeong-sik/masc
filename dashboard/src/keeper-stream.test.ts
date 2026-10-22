import { effect, untracked } from '@preact/signals'
import { captureToolObservations } from './keeper-tool-observations'
import type { KeeperChatStreamEvent } from './lib/keeper-chat-stream-contract'
import type { KeeperConversationEntry } from './types/core'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  _resetActiveKeeperStreamsForTests,
  _resetLiveSendRequestOwnersForTests,
  activeStreamRequestId,
  appendThreadEntry,
  chatHistoryEntriesFromRest,
  mergeServerHistoryEntries,
  claimLiveSendRequest,
  clearActiveStream,
  markLiveSendRequestAccepted,
  setActiveStream,
  updateThreadEntry,
} from './keeper-state'
import { keeperThreads, keeperToolApprovals } from './keeper-state'
import {
  _flushPendingKeeperStreamDeltasForTests,
  _resetKeeperStreamBuffersForTests,
  KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS,
  abortKeeperThreadMessage,
  applyKeeperOperationTurnEvent,
  applyKeeperStreamEvent,
  failKeeperStreamOperation,
  KEEPER_TOOL_RESULT_REFUSALS,
} from './keeper-stream'
import { parseSSEMessage } from './schemas/sse'
import {
  operationDeliveryProvenance,
  isOperationDeliveryProvenance,
} from './keeper-delivery-provenance'
import { toolCallDeliveryProvenance } from './test-support/tool-delivery-provenance'
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
      ? { deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result') }
      : {}),
    details: null,
  })
}

function requiredFixture<T>(value: T | null | undefined): T {
  if (value === null || value === undefined) throw new Error('missing required fixture')
  return value
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

  it('ignores a stale stop for an older response once a newer one begins', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_START',
      value: { content_generation: 3, stream_scope: 0, model: 'fixture' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_STOP',
      value: { content_generation: 2, stream_scope: 0 },
    })
    const live = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(live?.streamState).toBe('streaming')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_STOP',
      value: { content_generation: 3, stream_scope: 0 },
    })
    const stopped = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(stopped?.streamState).toBe('finalizing')
  })

  it('refuses a pre-floor stop once an attempt boundary cleared the current owner', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: { stream_scope: 0 },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_MODEL_CONTENT_ACTIVITY',
      value: { generation: 3, stream_scope: 0, block_index: 0, channel: 'text', state: 'observed' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED',
      value: { runtime_id: 'claude', attempt_index: 0 },
    })
    const entry = () => requiredFixture(keeperThreads.value.sangsu?.find(row => row.id === 'reply-1'))
    // The attempt cleared the current owner but kept the floor: a stop for
    // an older generation is stale and must not finalize the live response.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: { content_generation: 2, stream_scope: 0 },
    })
    expect(entry().streamState).toBe('streaming')
    // The floor generation's own stop still finalizes.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: { content_generation: 3, stream_scope: 0 },
    })
    expect(entry().streamState).toBe('finalizing')
  })

  it('accepts retry activity only for the observed running runtime attempt', () => {
    assistantEntry('op-retry')
    const retry = (runtime_id = 'claude', lane_attempt_index = 0): KeeperChatStreamEvent => ({
      type: 'CUSTOM', name: 'KEEPER_PROVIDER_RETRY', value: {
        attempt: { routing_run_id: 'routing-run', runtime_id, lane_attempt_index },
        retry: { observation_id: 'retry-id', attempt: 1, max_retries: 10, retry_delay_ms: 1234, error_status: null },
      },
    })
    const entry = () => requiredFixture(keeperThreads.value.sangsu?.find(row => row.id === 'reply-1'))
    applyKeeperStreamEvent('sangsu', 'reply-1', retry())
    expect(entry().streamState).toBe('opening')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', retry())
    expect(entry().streamState).toBe('retrying')
    expect(entry().text).toBe('')
    expect(entry().details).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', retry('foreign'))
    applyKeeperStreamEvent('sangsu', 'reply-1', retry('claude', 1))
    expect(entry().streamState).toBe('retrying')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-recovered' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-recovered', delta: 'answer' })
    expect(entry().streamState).toBe('streaming')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
    })
    expect(entry().text).toBe('answer')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' })
    const settled = entry().streamState
    applyKeeperStreamEvent('sangsu', 'reply-1', retry())
    expect(entry().streamState).toBe(settled)
    expect(entry().text).toBe('answer')
  })

  it('does not let an old attempt erase a current retry', () => {
    assistantEntry()
    const entry = () => requiredFixture(keeperThreads.value.sangsu?.find(row => row.id === 'reply-1'))
    for (const attempt_index of [0, 1]) applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_PROVIDER_RETRY', value: {
        attempt: { routing_run_id: 'routing-run', runtime_id: 'claude', lane_attempt_index: 1 },
        retry: { observation_id: 'retry-id', attempt: 1, max_retries: 10, retry_delay_ms: 1234, error_status: null },
      },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
    })
    for (const value of [null, { runtime_id: 'claude' }, { attempt_index: 2 }]) {
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_PROVIDER_RETRY', value: {
          attempt: { routing_run_id: 'old-routing-run', runtime_id: 'claude', lane_attempt_index: 0 },
          retry: { observation_id: 'old-retry-id', attempt: 1, max_retries: 10, retry_delay_ms: 1, error_status: null },
        },
      })
      expect(entry().runtimeAttempt?.index).toBe(1)
      expect(entry().streamState).toBe('retrying')
    }

  })

  it('deduplicates sequenced reasoning across transport replay and restores its prefix', () => {
    assistantEntry()
    const thinking = (delta: string): KeeperChatStreamEvent => ({
      type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta },
    })
    const source = (sequence: number) => ({ kind: 'operation' as const, operationId: 'op-1', sequence })
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).responseState).toMatchObject({ lastSequence: 10 })
    // In-memory batching is lost on reload; the restored entry is authoritative.
    _resetKeeperStreamBuffersForTests()
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking(' second'), source(11))
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps).toMatchObject([{ kind: 'think', text: 'first second' }])
  })

  it('does not reopen a stop for transport and unowned media notices', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'answer' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: null })
    const before = requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0])
    expect(before.streamState).toBe('finalizing')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CONNECTED', value: null })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_MEDIA_DELTA', value: { index: 0, media_type: 'image/png' } })
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).streamState).toBe(before.streamState)
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).delivery).toBe(before.delivery)
  })

  it('does not consume the valid frame sequence when a broadcast payload is malformed', () => {
    assistantEntry()
    const diagnostic = parseSSEMessage({ type: 'keeper_chat_operation_event', name: 'sangsu', operation_id: 'op-1', seq: 12,
      ag_ui_event: { type: 'TEXT_MESSAGE_CONTENT', delta: 123 } })
    expect(diagnostic?.seq).toBeUndefined()
    if (diagnostic?.ag_ui_event) applyKeeperStreamEvent('sangsu', 'reply-1', diagnostic.ag_ui_event as KeeperChatStreamEvent,
      { kind: 'operation', operationId: 'op-1', sequence: diagnostic.seq })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'valid counterpart' },
      { kind: 'operation', operationId: 'op-1', sequence: 12 })
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).rawText).toBe('valid counterpart')
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).responseState).toMatchObject({ lastSequence: 12 })
  })


  it('keeps newer retry progress after the real thinking publication timer fires', () => {
    vi.useFakeTimers()
    try {
      assistantEntry()
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: {
          index: 0, delta: 'exposed reasoning prefix',
        },
      })
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_PROVIDER_RETRY', value: {
          attempt: { routing_run_id: 'routing-run', runtime_id: 'claude', lane_attempt_index: 0 },
          retry: { observation_id: 'retry-id', attempt: 1, max_retries: 10, retry_delay_ms: 1234, error_status: null },
        },
      })
      const entry = () => requiredFixture(keeperThreads.value.sangsu?.find(row => row.id === 'reply-1'))
      expect(entry().streamState).toBe('retrying')
      vi.advanceTimersByTime(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
      expect(entry().streamState).toBe('retrying')
      expect(entry().traceSteps).toMatchObject([{ kind: 'think', text: 'exposed reasoning prefix' }])
      expect(entry().text).toBe('')
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: {
          index: 0, delta: ' recovered',
        },
      })
      vi.advanceTimersByTime(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
      expect(entry().streamState).toBe('thinking')
      expect(entry().traceSteps).toMatchObject([{ kind: 'think', text: 'exposed reasoning prefix recovered' }])

    } finally {
      _resetKeeperStreamBuffersForTests()
      vi.useRealTimers()
    }
  })

  it('does not publish retry onto a same-runtime operation replaced during thinking flush', () => {
    assistantEntry('original-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: {
        index: 0, delta: 'exposed reasoning',
      },
    })
    let armed = true
    const release = effect(() => {
      const current = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
      if (armed && current?.traceSteps?.some(step => step.kind === 'think')) {
        armed = false
        untracked(() => { keeperThreads.value = { sangsu: [{ ...current,
          deliveryProvenance: operationDeliveryProvenance('replacement-operation', 'terminal_result'),
          delivery: 'streaming', streamState: 'opening', text: 'replacement', rawText: 'replacement', traceSteps: [],
        }] } })
      }
    })
    try {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_PROVIDER_RETRY', value: {
          attempt: { routing_run_id: 'routing-run', runtime_id: 'claude', lane_attempt_index: 0 },
          retry: { observation_id: 'retry-id', attempt: 1, max_retries: 10, retry_delay_ms: 1234, error_status: null },
        },
      })
      const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
      expect(after.deliveryProvenance).toEqual(operationDeliveryProvenance('replacement-operation', 'terminal_result'))
      expect(after.streamState).toBe('opening')
      expect(after.text).toBe('replacement')
    } finally { release() }
  })

  it('deduplicates owned sequenced reasoning across transport replay and restores its prefix', () => {
    assistantEntry()
    const owner = { content_generation: 4, stream_scope: 2 }
    const thinking = (delta: string): KeeperChatStreamEvent => ({
      type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta, response: owner },
    })
    const source = (sequence: number) => ({ kind: 'operation' as const, operationId: 'op-1', sequence })
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    owner.content_generation = 99
    expect(keeperThreads.value.sangsu![0]!.traceSteps?.[0]).toMatchObject({ responseOwner: { content_generation: 4, stream_scope: 2 } })
    owner.content_generation = 4
    expect(keeperThreads.value.sangsu![0]!.responseState).toMatchObject({ lastSequence: 10 })
    expect(keeperThreads.value.sangsu![0]!.traceSteps).toMatchObject([{ kind: 'think', text: 'first', responseOwner: owner }])
    // In-memory batching is lost on reload; the restored entry is authoritative.
    _resetKeeperStreamBuffersForTests()
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking(' second'), source(11))
    expect(keeperThreads.value.sangsu![0]!.traceSteps).toMatchObject([{ kind: 'think', text: 'first second' }])
  })

  it('keeps reused reasoning block indices separate across owned responses', () => {
    assistantEntry()
    for (const generation of [4, 5]) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: `generation ${generation}`, response: { content_generation: generation, stream_scope: 0 } },
      }, { kind: 'operation', operationId: 'op-1', sequence: generation })
    }
    _flushPendingKeeperStreamDeltasForTests()
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps).toMatchObject([
      { text: 'generation 4', responseOwner: { content_generation: 4, stream_scope: 0 } },
      { text: 'generation 5', responseOwner: { content_generation: 5, stream_scope: 0 } },
    ])
  })

  it('rejects stale owned text even when its stream scope is larger', () => {
    assistantEntry()
    for (const [generation, scope, delta] of [[5, 0, 'current'], [4, 99, 'stale']] as const) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TEXT_MESSAGE_CONTENT', delta,
        textResponse: { content_generation: generation, stream_scope: scope },
      })
    }
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).rawText).toBe('current')
  })

  it('does not reopen an owned stop for transport and unowned media notices', () => {
    assistantEntry()
    const owner = { content_generation: 3, stream_scope: 0 }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'answer', textResponse: owner })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: owner })
    const before = requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0])
    expect(before.responseState).toMatchObject({ closed: owner })
    expect(before.streamState).toBe('finalizing')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CONNECTED', value: null })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_MEDIA_DELTA', value: { index: 0, media_type: 'image/png' } })
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).streamState).toBe(before.streamState)
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).delivery).toBe(before.delivery)
  })

  it('keeps an operation failed when a frame was dropped and the stream still finishes', () => {
    assistantEntry('op-1')
    const operation = { kind: 'operation', operationId: 'op-1' } as const
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'a' }, { ...operation, sequence: 1 })
    failKeeperStreamOperation('sangsu', 'reply-1', 'A Keeper stream frame does not match the protocol.')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'c' }, { ...operation, sequence: 3 })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED', threadId: 't', runId: 'r', timestamp: 1 } as never, { ...operation, sequence: 4 })
    const entry = keeperThreads.value.sangsu![0]!
    expect(entry.rawText).toBe('a')
    expect(entry.delivery).toBe('error')
    expect(entry.error).toBe('A Keeper stream frame does not match the protocol.')
    expect(entry.responseState).toMatchObject({ phase: 'failed', lastSequence: 4 })
  })

  it('keeps a finished response delivered when a frame fails to decode afterwards', () => {
    assistantEntry('op-1')
    const operation = { kind: 'operation', operationId: 'op-1' } as const
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'done' }, operation)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED', threadId: 't', runId: 'r', timestamp: 1 } as never, operation)
    failKeeperStreamOperation('sangsu', 'reply-1', 'late undecodable frame')
    expect(keeperThreads.value.sangsu![0]!).toMatchObject({ delivery: 'delivered', error: null, rawText: 'done' })
  })

  it('treats a server-sent sse_parse_failed protocol error as a diagnostic, not a failure', () => {
    assistantEntry('op-matched')
    const operation = { kind: 'operation', operationId: 'op-matched' } as const
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'a' }, operation)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: { kind: 'sse_parse_failed', reason: 'provider chunk could not be parsed' } }, operation)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'b' }, operation)
    const entry = keeperThreads.value.sangsu![0]!
    expect(entry).toMatchObject({ rawText: 'ab', delivery: 'streaming' })
    expect(entry.responseState).not.toMatchObject({ phase: 'failed' })
    expect(entry.error).toContain('sse_parse_failed')
  })

  it('keeps content-activity metadata from reopening a stopped owned response', () => {
    appendThreadEntry('sangsu', {
      id: 'reply-1',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '',
      rawText: '',
      timestamp: null,
      delivery: 'sending',
      streamState: 'opening',
      details: null,
    })
    const owner = { content_generation: 3, stream_scope: 0 }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'answer', textResponse: owner })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: owner })
    const stopped = keeperThreads.value.sangsu?.[0]
    expect(stopped?.responseState).toMatchObject({ closed: owner })
    expect(stopped?.streamState).toBe('finalizing')
    // Settle the provider/usage details the authoritative reply event stamps
    // after the response body has advanced.
    updateThreadEntry('sangsu', 'reply-1', entry => ({
      ...entry,
      details: {
        providerMessageId: 'msg-1',
        modelUsed: 'model-x',
        stopReason: 'stop_sequence',
        usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 },
        costUsd: 0.01,
      },
    }))
    // A newer-generation activity notice is side metadata with no authored
    // body: it raises the ownership floor but must not reopen the response
    // or wipe the settled provider/usage details.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_MODEL_CONTENT_ACTIVITY',
      value: { generation: 4, stream_scope: 0, block_index: 2, channel: 'text', state: 'observed' },
    })
    const after = keeperThreads.value.sangsu?.[0]
    expect(after?.responseState).toMatchObject({ floor: { content_generation: 4, stream_scope: 0 } })
    expect(after?.streamState).toBe(stopped?.streamState)
    expect(after?.details?.providerMessageId).toBe('msg-1')
    expect(after?.details?.modelUsed).toBe('model-x')
    expect(after?.details?.stopReason).toBe('stop_sequence')
    expect(after?.details?.usage).toMatchObject({ totalTokens: 3 })
    expect(after?.details?.costUsd).toBe(0.01)
  })

  it('persists full unsequenced reasoning at the scheduled flush and resumes it after reload', () => {
    vi.useFakeTimers()
    try {
      const operationId = 'reasoning-reload'
      upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'inspect', submittedAt: 1 })
      assistantEntry(operationId)
      const owner = { content_generation: 8, stream_scope: 0 }
      const prefix = 'Reasoning paragraph with preserved whitespace.\n'.repeat(1000)
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: prefix, response: owner } })
      vi.advanceTimersByTime(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
      const draft = requiredFixture(trackedKeeperChatOperationsForKeeper('sangsu')[0]).assistantDraft!
      expect(draft.traceSteps?.[0]).toMatchObject({ text: prefix, responseOwner: owner })
      _resetKeeperStreamBuffersForTests()
      keeperThreads.value = { sangsu: [{ ...requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]), traceSteps: draft.traceSteps, responseState: draft.responseState }] }
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: 'continuation', response: owner } })
      _flushPendingKeeperStreamDeltasForTests()
      expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps?.[0]).toMatchObject({ text: `${prefix}continuation` })
    } finally {
      _resetKeeperStreamBuffersForTests()
      vi.useRealTimers()
    }
  })

  it('reconciles the admitted name on one exact occurrence while retaining the wire identity', () => {
    assistantEntry()
    const start: KeeperChatStreamEvent = { type: 'TOOL_CALL_START', ...toolOccurrence(2, 7),
      toolCallId: 'same-provider-id', providerMessageId: 'message', toolCallName: 'keeper_skill1' }
    const admission: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_CALL_ADMITTED',
      value: { ...toolOccurrence(2, 7), toolCallId: 'same-provider-id', providerMessageId: 'message',
        providerToolName: 'keeper_skill1', toolCallName: 'keeper_skill' } }
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END', ...toolOccurrence(2, 7) })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admission)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admission)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', start)).toBeNull()
    const tools = keeperThreads.value.sangsu?.filter(entry => entry.role === 'tool') ?? []
    expect(tools).toHaveLength(1)
    expect(tools[0]).toMatchObject({ label: 'keeper_skill', toolProviderName: 'keeper_skill1',
      toolAdmittedName: 'keeper_skill', toolCallEnded: true })
    const parent = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(parent?.traceSteps?.filter(step => step.kind === 'tool')).toMatchObject([{ name: 'keeper_skill' }])
  })

  it('uses server occurrence rather than reused provider IDs to admit a name', () => {
    assistantEntry()
    for (const scope of [1, 2]) applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START', ...toolOccurrence(0, scope), toolCallId: 'same', toolCallName: 'keeper_skill1',
    })
    const admit = (scope: number, providerName: string, toolCallId = 'same'): KeeperChatStreamEvent => ({
      type: 'CUSTOM', name: 'KEEPER_TOOL_CALL_ADMITTED', value: {
        ...toolOccurrence(0, scope), toolCallId, providerToolName: providerName, toolCallName: 'keeper_skill',
      },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admit(2, 'keeper_skill1'))).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admit(1, 'another-name'))).toBeTruthy()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admit(1, 'keeper_skill1', 'other-id'))).toBeTruthy()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', admit(3, 'keeper_skill1'))).toBeTruthy()
    const tools = keeperThreads.value.sangsu?.filter(entry => entry.role === 'tool') ?? []
    expect(tools.map(entry => entry.label)).toEqual(['keeper_skill1', 'keeper_skill'])
  })

  it('preserves current speech when an existing tool START is replayed', () => {
    assistantEntry()
    const start: KeeperChatStreamEvent = { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'provider-tool' }
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'current speech' })
    const before = requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')!
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    const after = requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')!
    expect(after.rawText).toBe('current speech')
    expect(after.traceSteps).toEqual(before.traceSteps)
  })

  it('retains late tool facts without reopening a completed response or moving its body', () => {
    const operationId = 'finished-with-async-tools'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'final answer' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' }, source)
    const broadcast = (event: KeeperChatStreamEvent) => applyKeeperOperationTurnEvent('sangsu', { operationId, event })
    const before = requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')!
    expect(before.responseState).toMatchObject({ phase: 'terminal' })
    expect(before.delivery).toBe('delivered')
    broadcast({ type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'late-tool' })
    broadcast({ type: 'TOOL_CALL_ARGS', ...toolOccurrence(), toolCallId: 'late-tool', snapshot: '{"path":"file"}' })
    broadcast({ type: 'TOOL_CALL_END', ...toolOccurrence(), toolCallId: 'late-tool' })
    broadcast({ type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'late-tool', executionId: 'late-execution' } })
    const after = requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')!
    expect(after).toMatchObject({ text: 'final answer', rawText: 'final answer', delivery: 'delivered', streamState: null, responseState: { phase: 'terminal' } })
    expect(after.traceSteps).toMatchObject([{ kind: 'tool', name: 'Read', status: 'ok', executionId: 'late-execution', args: '{"path":"file"}' }])
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.executionId === 'late-execution')).toMatchObject({ delivery: 'delivered', toolCallEnded: true })
  })

  it.each(['history', 'interrupted'] as const)('records late tools on %s without granting activity to its response', delivery => {
    const operationId = 'canonical-late-tool'
    appendThreadEntry('sangsu', { id: 'canonical-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'canonical answer', rawText: 'canonical answer', timestamp: '2026-10-11T00:00:00Z', delivery, streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' } })
    const before = requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'canonical-reply')!
    expect(before).toMatchObject({ delivery, streamState: null, rawText: 'canonical answer', text: 'canonical answer' })
    expect(before.traceSteps).toMatchObject([{ kind: 'tool', name: 'Read', status: 'pending' }])
    const error = applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(9), executionId: 'unmatched-execution' } } })
    expect(error).not.toBeNull()
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'canonical-reply')).toMatchObject({
      delivery, streamState: null, rawText: 'canonical answer', text: 'canonical answer', error,
    })
  })

  it('recognizes a replayed tool start already persisted under the server row id', () => {
    const operationId = 'persisted-tool-replay'
    appendThreadEntry('sangsu', { id: 'hist-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'canonical answer', rawText: 'canonical answer', timestamp: '2026-10-11T00:00:00Z', delivery: 'history', streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
    appendThreadEntry('sangsu', { id: 'server-row-7', role: 'tool', source: 'tool_result', label: 'Read',
      text: '{"path":"file"}', rawText: '{"path":"file"}', timestamp: '2026-10-11T00:00:01Z', delivery: 'history', streamState: null,
      toolCallId: 'tc-persisted', toolCallEnded: true,
      deliveryProvenance: {
        delivery_key: { kind: 'operation', operation_id: operationId },
        transcript_slot: { kind: 'tool_delivery', ordinal: 0 },
      },
      details: null })

    applyKeeperOperationTurnEvent('sangsu', { operationId, event: {
      type: 'TOOL_CALL_START', ...toolOccurrence(3), toolCallId: 'tc-persisted', toolCallName: 'Read',
    } })

    const tools = (keeperThreads.value.sangsu ?? []).filter(entry => entry.role === 'tool')
    expect(tools).toHaveLength(1)
    expect(tools[0]).toMatchObject({ id: 'server-row-7', delivery: 'history' })
    expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'hist-reply')?.traceSteps).toBeUndefined()
  })

  it('still creates a streaming occurrence for a replayed start with no persisted provenance', () => {
    const operationId = 'unpersisted-tool-replay'
    appendThreadEntry('sangsu', { id: 'hist-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'canonical answer', rawText: 'canonical answer', timestamp: '2026-10-11T00:00:00Z', delivery: 'history', streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })

    applyKeeperOperationTurnEvent('sangsu', { operationId, event: {
      type: 'TOOL_CALL_START', ...toolOccurrence(3), toolCallId: 'tc-unpersisted', toolCallName: 'Write',
    } })

    expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-delivery-hist-reply-stream-0-block-3')).toMatchObject({
      role: 'tool',
      label: 'Write',
      delivery: 'streaming',
    })
  })

  it('admits an occurrence-scoped quarantine replay so the late occurrence is marked errored', () => {
    const operationId = 'quarantined-tool-replay'
    appendThreadEntry('sangsu', { id: 'quar-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'canonical answer', rawText: 'canonical answer', timestamp: '2026-10-11T00:00:00Z', delivery: 'history', streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })

    // No provider tool_call_id on the replayed start, so the observation
    // path creates the local occurrence row for the quarantine to mark.
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: {
      type: 'TOOL_CALL_START', ...toolOccurrence(5), toolCallName: 'Read',
    } })
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: {
        kind: 'tool_args_without_start',
        index: 5,
        reason: 'occurrence quarantined by the server',
        quarantined_occurrence: { ...toolOccurrence(5), providerMessageId: 'provider-message-1' },
      },
    } })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-delivery-quar-reply-stream-0-block-5')
    expect(tool).toMatchObject({ delivery: 'error', toolCallEnded: true })
    expect(tool?.error).toContain('tool_args_without_start')
    expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'quar-reply')?.traceSteps).toMatchObject([
      { kind: 'tool', name: 'Read', status: 'err' },
    ])
  })

  it('keeps tools live after an owned model stop while the operation is still running', () => {
    assistantEntry()
    const owner = { content_generation: 3, stream_scope: 0 }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'intermediate speech', textResponse: owner })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: owner })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' })
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')).toMatchObject({
      delivery: 'streaming', streamState: 'streaming', responseState: { phase: 'running', closed: owner },
    })
  })

  it('binds late args and results to the same tool occurrence after its assistant row is replaced', () => {
    const operationId = 'stable-tool-parent'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const start: KeeperChatStreamEvent = { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'reused-provider' }
    applyKeeperStreamEvent('sangsu', 'reply-1', start, source)
    const originalTool = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' }, source)
    mergeServerHistoryEntries('sangsu', [{ ...requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')!,
      id: 'canonical-parent', delivery: 'history', traceSteps: undefined }])
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: start })
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'TOOL_CALL_ARGS', ...toolOccurrence(), toolCallId: 'reused-provider', snapshot: '{"path":"file"}' } })
    expect(applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'reused-provider', executionId: 'stable-execution' } } })).toBeNull()
    const tools = requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')
    expect(tools.map(row => row.id)).toEqual([originalTool.id])
    expect(tools[0]).toMatchObject({ executionId: 'stable-execution', rawText: '{"path":"file"}', delivery: 'delivered' })
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'canonical-parent')?.traceSteps).toMatchObject([
      { kind: 'tool', executionId: 'stable-execution', status: 'ok' },
    ])
  })

  it('keeps a quarantined provisional occurrence beside a committed execution at ordinal zero', () => {
    assistantEntry('quarantine-gap')
    const source = { kind: 'operation' as const, operationId: 'quarantine-gap' }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: { kind: 'tool_start_duplicate_index', quarantined_occurrence: toolOccurrence() } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(1), toolCallName: 'Write' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(1), executionId: 'valid-execution' } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey: { kind: 'operation', operation_id: 'quarantine-gap' }, executionId: 'valid-execution', ordinal: 0 } }, source)
    const entries = requiredFixture(keeperThreads.value.sangsu)
    const captured = captureToolObservations(entries.find(entry => entry.id === 'reply-1')!, entries)
    expect(captured).toMatchObject({ kind: 'known', entries: [
      { toolOccurrenceQuarantined: true, deliveryProvenance: null },
      { executionId: 'valid-execution', toolTranscriptOrdinal: 0, deliveryProvenance: { transcript_slot: { kind: 'tool_call', ordinal: 0 } } },
    ] })
  })

  it('owns a copy of the committed delivery key and refuses canonical key replacement', () => {
    assistantEntry('binding-copy')
    const source = { kind: 'operation' as const, operationId: 'binding-copy' }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { ...toolOccurrence(), executionId: 'execution' } }, source)
    const key = { kind: 'operation_native' as const, operation_id: 'binding-copy', continuation_id: 'native-a' }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey: key, executionId: 'execution', ordinal: 0 } }, source)
    key.continuation_id = 'mutated'
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.role === 'tool')?.deliveryProvenance?.delivery_key).toMatchObject({ continuation_id: 'native-a' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey: { ...key, continuation_id: 'native-b' }, executionId: 'execution', ordinal: 0 } }, source)
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')?.toolObservationAuthority).toBe('unavailable')
  })

  it.each([false, true])('uses the committed server ordinal regardless of result ordering (commitFirst=%s)', commitFirst => {
    assistantEntry('committed-ordinal')
    const source = { kind: 'operation' as const, operationId: 'committed-ordinal' }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }, source)
    const committed: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey: { kind: 'operation', operation_id: 'committed-ordinal' }, executionId: 'execution', ordinal: 7 } }
    if (commitFirst) applyKeeperStreamEvent('sangsu', 'reply-1', committed, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { ...toolOccurrence(), executionId: 'execution' } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', committed, source)
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.role === 'tool')).toMatchObject({ toolTranscriptOrdinal: 7,
      deliveryProvenance: { transcript_slot: { kind: 'tool_call', execution_id: 'execution', ordinal: 7 } } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { ...committed, value: { ...committed.value, ordinal: 8 } }, source)
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'reply-1')?.toolObservationAuthority).toBe('unavailable')
  })

  it('retains unavailable tool authority when canonical history replaces its parent', () => {
    const operationId = 'unavailable-tool-parent'
    assistantEntry(operationId)
    keeperThreads.value = { ...keeperThreads.value, sangsu: requiredFixture(keeperThreads.value.sangsu).map(entry => ({ ...entry,
      toolObservationAuthority: 'unavailable' as const })) }
    mergeServerHistoryEntries('sangsu', [{ ...requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]), id: 'canonical-unavailable-parent',
      toolObservationAuthority: undefined, delivery: 'history' }])
    const source = { kind: 'operation' as const, operationId }
    expect(applyKeeperStreamEvent('sangsu', 'canonical-unavailable-parent', { type: 'TOOL_CALL_START',
      ...toolOccurrence(), toolCallName: 'Read' }, source)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'canonical-unavailable-parent', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'must-not-bind' } }, source)).toBeNull()
    expect(requiredFixture(keeperThreads.value.sangsu).some(entry => entry.role === 'tool')).toBe(false)
    expect(requiredFixture(keeperThreads.value.sangsu).find(entry => entry.id === 'canonical-unavailable-parent')?.toolObservationAuthority).toBe('unavailable')
  })

  it('rejects contradictory provider correlation on an already bound result replay', () => {
    assistantEntry('result-replay-validation')
    const source = { kind: 'operation' as const, operationId: 'result-replay-validation' }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'provider-a' }, source)
    const result: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'same-execution', toolCallId: 'provider-a' } }
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', result, source)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', result, source)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', { ...result,
      value: { ...result.value, toolCallId: 'provider-b' } }, source)).toBe(KEEPER_TOOL_RESULT_REFUSALS.providerCorrelationConflict)
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')).toMatchObject([
      { executionId: 'same-execution', toolCallId: 'provider-a' },
    ])
  })

  it.each([[false, false], [true, false], [false, true], [true, true]])('binds history before result (conflict=%s, continuation=%s)', (conflict, continuation) => {
    const operationId = 'history-before-result'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'live-provider' }, source)
    const planned = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    const parentProvenance = continuation
      ? { delivery_key: { kind: 'operation_native' as const, operation_id: operationId, continuation_id: 'native' }, transcript_slot: { kind: 'terminal_result' as const } }
      : operationDeliveryProvenance(operationId, 'terminal_result')
    mergeServerHistoryEntries('sangsu', [{ ...planned, id: 'canonical-executed-tool', toolOwnerKey: undefined,
      executionId: 'history-execution', delivery: 'history', rawText: 'canonical args',
      toolCallId: conflict ? 'different-provider' : 'live-provider',
      toolOccurrence: undefined,
      deliveryProvenance: toolCallDeliveryProvenance(parentProvenance, 'history-execution', 0),
    }])
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')).toHaveLength(2)
    const result = applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'history-execution' } }, source)
    if (conflict) {
      expect(result).toBe(KEEPER_TOOL_RESULT_REFUSALS.providerCorrelationConflict)
      expect(keeperThreads.value.sangsu?.filter(row => row.role === 'tool')).toHaveLength(2)
      expect(keeperThreads.value.sangsu?.find(row => row.id === planned.id)?.executionId).toBeUndefined()
      return
    }
    expect(result).toBeNull()
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')).toMatchObject([
      { id: 'canonical-executed-tool', rawText: 'canonical args', toolCallEnded: true,
        toolOccurrence: { kind: 'identified', streamScope: 0, blockIndex: 0 } },
    ])
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')?.traceSteps).toMatchObject([
      { kind: 'tool', toolOccurrenceId: 'canonical-executed-tool', executionId: 'history-execution', status: 'ok' },
    ])
  })

  it('retains authoritative quarantine across parent replacement and transient buffer reset', () => {
    const operationId = 'stable-quarantine-parent'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: { kind: 'tool_start_duplicate_index', quarantined_occurrence: toolOccurrence() } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' }, source)
    mergeServerHistoryEntries('sangsu', [{ ...requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')!, id: 'canonical-quarantine-parent', delivery: 'history' }])
    _resetKeeperStreamBuffersForTests()
    expect(applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'must-not-bind' } } })).toBe(KEEPER_TOOL_RESULT_REFUSALS.quarantinedOccurrence)
    expect(keeperThreads.value.sangsu?.find(row => row.role === 'tool')).toMatchObject({ toolOccurrenceQuarantined: true, delivery: 'error' })
    expect(keeperThreads.value.sangsu?.some(row => row.executionId === 'must-not-bind')).toBe(false)
  })

  it.each([false, true])('preserves tool coordinates and trace links through canonical replacement (duplicate=%s)', duplicate => {
    const operationId = 'canonical-tool-occurrence'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const start: KeeperChatStreamEvent = { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }
    applyKeeperStreamEvent('sangsu', 'reply-1', start, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { ...toolOccurrence(), executionId: 'canonical-execution' } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey: { kind: 'operation', operation_id: 'canonical-tool-occurrence' }, executionId: 'canonical-execution', ordinal: 0 } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' }, source)
    const originalTool = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    const originalReply = requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')!
    mergeServerHistoryEntries('sangsu', [
      { ...originalTool, id: 'persisted-tool', toolOccurrence: undefined, toolOccurrenceQuarantined: undefined, toolCallEnded: undefined, delivery: 'history' },
      ...(duplicate ? [{ ...originalTool, id: 'duplicate-persisted-tool', toolOccurrence: undefined, toolOccurrenceQuarantined: undefined, toolCallEnded: undefined, delivery: 'history' as const }] : []),
      { ...originalReply, id: 'persisted-reply', delivery: 'history', traceSteps: duplicate
        ? originalReply.traceSteps?.map(step => step.kind === 'tool' ? { ...step, toolOccurrenceId: 'duplicate-persisted-tool' } : step)
        : undefined },
    ])
    applyKeeperOperationTurnEvent('sangsu', { operationId, event: start })
    expect(applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'canonical-execution' } } })).toBeNull()
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool').map(row => row.id)).toEqual(['persisted-tool'])
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'persisted-reply')?.traceSteps).toMatchObject([
      { kind: 'tool', toolOccurrenceId: 'persisted-tool', executionId: 'canonical-execution' },
    ])
  })

  it.each([true, false])('converges an acknowledged tool with canonical history in either arrival order (commit first %s)', commitFirst => {
    const operationId = 'acknowledged-tool-operation'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const deliveryKey = { kind: 'operation' as const, operation_id: operationId }
    const commit: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'acknowledged-execution', ordinal: 0 } }
    const result: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'provider-tool', executionId: 'acknowledged-execution' } }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(),
      toolCallId: 'provider-tool', toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', commitFirst ? commit : result, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', commitFirst ? result : commit, source)
    const tool = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    expect(tool).toMatchObject({ executionId: 'acknowledged-execution', toolTranscriptOrdinal: 0,
      deliveryProvenance: { delivery_key: deliveryKey, transcript_slot: { kind: 'tool_call', execution_id: 'acknowledged-execution', ordinal: 0 } } })
    mergeServerHistoryEntries('sangsu', [{ ...tool, id: 'canonical-tool', text: 'stored output', delivery: 'history',
      toolOccurrence: undefined, toolCallEnded: undefined }])
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool').map(row => row.id)).toEqual(['canonical-tool'])
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')?.traceSteps).toMatchObject([
      { kind: 'tool', toolOccurrenceId: 'canonical-tool', executionId: 'acknowledged-execution' },
    ])
    applyKeeperStreamEvent('sangsu', 'reply-1', commit, source)
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')?.toolObservationAuthority).not.toBe('unavailable')
  })

  it.each([true, false])('converges canonical history that arrived before the tool result (commit before history %s)', commitBeforeHistory => {
    const operationId = 'early-history-operation'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const deliveryKey = { kind: 'operation' as const, operation_id: operationId }
    const commit: KeeperChatStreamEvent = { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'early-execution', ordinal: 0 } }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(),
      toolCallId: 'provider-tool', toolCallName: 'Read' }, source)
    if (commitBeforeHistory) applyKeeperStreamEvent('sangsu', 'reply-1', commit, source)
    mergeServerHistoryEntries('sangsu', [{ id: 'early-canonical', role: 'tool', source: 'tool_result', label: 'Read',
      text: 'stored output', delivery: 'history', executionId: 'early-execution',
      deliveryProvenance: { delivery_key: deliveryKey, transcript_slot: { kind: 'tool_call', execution_id: 'early-execution', ordinal: 0 } } }])
    if (!commitBeforeHistory) applyKeeperStreamEvent('sangsu', 'reply-1', commit, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'provider-tool', executionId: 'early-execution' } }, source)
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool').map(row => row.id)).toEqual(['early-canonical'])
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'early-canonical')).toMatchObject({
      toolOwnerKey: deliveryKey, executionId: 'early-execution', toolOccurrence: { streamScope: 0, blockIndex: 0 },
    })
  })

  it('folds canonical history into the tool row when the result arrives after the acknowledgement', () => {
    const operationId = 'late-result-operation'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const deliveryKey = { kind: 'operation' as const, operation_id: operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(),
      toolCallId: 'provider-tool', toolCallName: 'Read' }, source)
    appendThreadEntry('sangsu', { id: 'late-canonical', role: 'tool', source: 'tool_result', label: 'Read',
      text: 'stored output', delivery: 'history',
      deliveryProvenance: { delivery_key: deliveryKey, transcript_slot: { kind: 'tool_call', execution_id: 'late-execution', ordinal: 0 } } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'late-execution', ordinal: 0 } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'provider-tool', executionId: 'late-execution' } }, source)
    const tools = requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')
    expect(tools.map(row => row.id)).toEqual(['late-canonical'])
    expect(tools[0]?.toolOwnerKey).toEqual(deliveryKey)
  })

  it('refuses an acknowledgement whose canonical history row is quarantined or duplicated', () => {
    const operationId = 'conflicting-canonical-operation'
    const deliveryKey = { kind: 'operation' as const, operation_id: operationId }
    const canonicalRow = (id: string, extra: Partial<KeeperConversationEntry> = {}): KeeperConversationEntry => ({
      id, role: 'tool', source: 'tool_result', label: 'Read', text: 'stored output', delivery: 'history',
      deliveryProvenance: { delivery_key: deliveryKey, transcript_slot: { kind: 'tool_call', execution_id: 'canonical-execution', ordinal: 0 } },
      ...extra })
    for (const [label, rows] of [
      ['quarantined', [canonicalRow('canonical-a', { toolOccurrenceQuarantined: true })]],
      ['duplicated', [canonicalRow('canonical-a'), canonicalRow('canonical-b')]],
    ] as const) {
      keeperThreads.value = {}
      assistantEntry(operationId)
      const source = { kind: 'operation' as const, operationId }
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(),
        toolCallId: 'provider-tool', toolCallName: 'Read' }, source)
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
        value: { ...toolOccurrence(), toolCallId: 'provider-tool', executionId: 'canonical-execution' } }, source)
      for (const row of rows) appendThreadEntry('sangsu', row)
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
        value: { deliveryKey, executionId: 'canonical-execution', ordinal: 0 } }, source)
      expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1'), label).toMatchObject({
        toolObservationAuthority: 'unavailable',
        error: 'Acknowledged tool transcript conflicts with canonical history',
      })
      expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool' && row.id.startsWith('canonical')), label)
        .toHaveLength(rows.length)
    }
  })

  it('refuses an acknowledgement for a tool row quarantined under a disputed occurrence', () => {
    const operationId = 'quarantined-resource-operation'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    const deliveryKey = { kind: 'operation' as const, operation_id: operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(),
      toolCallId: 'provider-tool', toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), toolCallId: 'provider-tool', executionId: 'quarantined-execution' } }, source)
    const tool = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    updateThreadEntry('sangsu', tool.id, entry => ({ ...entry, toolOccurrenceQuarantined: true }))
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey, executionId: 'quarantined-execution', ordinal: 0 } }, source)
    const after = requiredFixture(keeperThreads.value.sangsu)
    expect(after.find(row => row.id === 'reply-1')).toMatchObject({
      toolObservationAuthority: 'unavailable',
      error: 'Acknowledged tool transcript is quarantined under a disputed occurrence',
    })
    expect(after.find(row => row.id === tool.id)?.deliveryProvenance ?? null).toBeNull()
  })

  it('keeps every disputed tool coordinate quarantined through canonical replacement', () => {
    const operationId = 'conflicting-tool-coordinates'
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY', value: { ...toolOccurrence(), executionId: 'conflicting-execution' } }, source)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED', value: { deliveryKey: { kind: 'operation', operation_id: operationId }, executionId: 'conflicting-execution', ordinal: 0 } }, source)
    const originalTool = requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')!
    appendThreadEntry('sangsu', { ...originalTool, id: 'disputed-tool-alias', toolOccurrence: { kind: 'identified', streamScope: 1, blockIndex: 1 } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' }, source)
    mergeServerHistoryEntries('sangsu', [
      { ...originalTool, id: 'canonical-disputed-tool', delivery: 'history', toolOccurrence: undefined },
      { ...requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'reply-1')!, id: 'canonical-disputed-parent', delivery: 'history' },
    ])
    for (const occurrence of [toolOccurrence(), toolOccurrence(1, 1)]) {
      applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'TOOL_CALL_START', ...occurrence, toolCallName: 'Read' } })
      expect(applyKeeperOperationTurnEvent('sangsu', { operationId, event: { type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
        value: { ...occurrence, executionId: 'must-not-rebind' } } })).toBe(KEEPER_TOOL_RESULT_REFUSALS.quarantinedOccurrence)
    }
    expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool').map(row => row.id)).toEqual(['canonical-disputed-tool'])
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === 'canonical-disputed-tool')).toMatchObject({
      toolOccurrenceQuarantined: true, toolOccurrence: { kind: 'conflicting', coordinates: [
        { streamScope: 0, blockIndex: 0 }, { streamScope: 1, blockIndex: 1 },
      ] },
    })
  })

  it.each(['observed', 'ended'] as const)('keeps content %s metadata outside model progress and body state', state => {
    assistantEntry()
    for (const hasBody of [false, true]) {
      if (hasBody) {
        applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'authored text' })
      }
      const before = requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0])
      expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_MODEL_CONTENT_ACTIVITY',
        value: { generation: 17, stream_scope: 0, block_index: 2, channel: 'text', state },
      })).toBeNull()
      // This view does not draw the side metadata. It must neither announce
      // model progress nor finalize a live response or append authored bytes.
      expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).rawText).toBe(before.rawText)
      expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).delivery).not.toBe('ok')
      const after = keeperThreads.value.sangsu![0]!
      expect({ ...after, responseState: undefined }).toEqual({ ...before, responseState: undefined })
      // Observed activity raises the ownership floor; ended activity names no response.
      if (state === 'observed') expect(after.responseState).toMatchObject({ floor: { content_generation: 17, stream_scope: 0 } })
      else expect(after.responseState).toEqual(before.responseState)
    }
  })

  it('keeps parsed native observer metadata outside authored text and MASC tool receipts', () => {
    const operationId = 'native-observer-operation'
    assistantEntry(operationId)
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallId: 'reused-id', toolCallName: 'Read',
    })
    // Tool starts move earlier speech into the progress trail. Establish the
    // current authored body after that existing boundary, before native events.
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'before' })
    const observation = { ...toolOccurrence(), toolCallId: 'reused-id', toolCallName: 'Read' }
    const events: KeeperChatStreamEvent[] = [
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_START', value: observation },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: { kind: 'heartbeat_reported', elapsed_seconds: 30 } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: { kind: 'heartbeat_reported', elapsed_seconds: 3 } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: { kind: 'output_observed', byte_count: 13 } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: { kind: 'message_reported', message: 'not authored text' } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: {
        kind: 'retry_reported', agent_id: 'child', subagent_type: 'Explore', attempt: 1,
        max_retries: 3, retry_delay_ms: 1500, error_status: 529, error_category: 'overloaded',
      } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_PROGRESS', value: { ...observation, progress: {
        kind: 'retry_cleared', agent_id: 'child', subagent_type: 'Explore',
      } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_END', value: { ...observation, completion: { kind: 'completion_reported', exit_code: 17 } } },
      { type: 'CUSTOM', name: 'KEEPER_NATIVE_TOOL_END', value: observation },
    ]
    const before = keeperThreads.value
    for (const event of events) {
      const wire = { ...event, threadId: 'keeper:sangsu', runId: 'run-1', timestamp: 1_712_000_000 }
      const parsed = parseSSEMessage({
        type: 'keeper_chat_operation_event', name: 'sangsu', operation_id: operationId,
        ag_ui_event: wire,
      })
      expect(parsed?.ag_ui_event).toEqual(wire)
      if (!parsed) throw new Error('valid native observation was rejected')
      expect(applyKeeperOperationTurnEvent('sangsu', {
        operationId, event: parsed.ag_ui_event as KeeperChatStreamEvent,
      })).toBeNull()
      // No native rows are rendered by this view yet. Even a provider id and
      // scope/index colliding with a MASC tool must not settle that receipt,
      // append native progress as speech, or change current model activity.
      expect(keeperThreads.value).toBe(before)
    }
    expect(applyKeeperOperationTurnEvent('sangsu', {
      operationId, event: { type: 'TEXT_MESSAGE_CONTENT', delta: ' after' },
    })).toBeNull()
    expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')?.rawText).toBe('before after')
  })

  it.each([false, true])('keeps an input-wait stream nonterminal after prior delivery %s and admits the later actual answer', (posted) => {
    const operationId = 'original-input-operation'
    assistantEntry(operationId)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_STARTED' })
    const wire = { type: 'CUSTOM', threadId: 'keeper:original-input-operation',
      runId: 'original-input-run', timestamp: 1, name: 'KEEPER_REPLY_DETAILS', value: {
      reply: 'Which original branch?', turn_outcome: 'waiting_for_input',
      turn_ref: 'original#1',
    } }
    const parsed = parseSSEMessage({ type: 'keeper_chat_operation_event', name: 'sangsu',
      operation_id: operationId, ag_ui_event: wire })
    expect(parsed?.ag_ui_event).toEqual(wire)
    if (!parsed) throw new Error('typed input wait failed SSE decoding')
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', parsed.ag_ui_event as KeeperChatStreamEvent,
      {kind: 'operation', operationId})).toBeNull()
    if (posted) applyKeeperStreamEvent('sangsu', 'reply-1', {type: 'CUSTOM', name: 'KEEPER_EXTERNAL_EFFECT_COMPLETED',
      value: {target: {kind: 'dashboard'}}}, {kind: 'operation', operationId})
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' },
      {kind: 'operation', operationId})).toBeNull()
    const waiting = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(waiting).toMatchObject({ text: '', rawText: 'Which original branch?', delivery: 'queued',
      details: {turnOutcome: 'waiting_for_input'}, responseState: {phase: 'awaiting-continuation'} })
    expect(waiting?.blocks).toContainEqual({t: 'status', kind: 'waiting_for_input'})
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {type: 'RUN_STARTED'},
      {kind: 'operation', operationId})).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: {reply: 'Actual answer', turn_outcome: 'visible_reply', turn_ref: 'original#2'}},
      {kind: 'operation', operationId})).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', {type: 'RUN_FINISHED'}, {kind: 'operation', operationId})
    const completed = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(completed).toMatchObject({text: 'Actual answer', delivery: 'delivered',
      responseState: {phase: 'terminal'}})
    expect(completed?.blocks?.some(block => block.t === 'status')).toBe(false)
  })

  it('streams text into the selected assistant entry', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '안녕',
      textStreamScope: 2,
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('안녕')
    expect(entry?.delivery).toBe('streaming')
  })

  it.each([false, true])('clears checkpoint control status while retaining structured content %s', (withContent) => {
    assistantEntry()
    if (withContent) keeperThreads.value = { ...keeperThreads.value, sangsu: keeperThreads.value.sangsu!.map(entry => ({ ...entry,
      blocks: [{ t: 'thinking' as const, content: 'exposed reasoning', redacted: false },
        { t: 'attach' as const, name: 'result.txt' }],
    })) }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CONTINUATION_CHECKPOINT',
      value: { message: 'checkpoint', request_id: 'request-1' } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_STARTED' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: { reply: 'completed answer', turn_ref: 'turn-1', turn_outcome: 'visible_reply' } })
    const completed = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(completed?.text).toBe('completed answer')
    expect(completed?.blocks?.some(block => block.t === 'status')).toBe(false)
    if (withContent) expect(completed?.blocks).toEqual([
      { t: 'thinking', content: 'exposed reasoning', redacted: false }, { t: 'attach', name: 'result.txt' },
      { t: 'p', html: 'completed answer' },
    ])
  })
  it('rebuilds final prose while retaining exposed reasoning and attachments', () => {
    assistantEntry()
    keeperThreads.value = { sangsu: keeperThreads.value.sangsu!.map(entry => ({ ...entry,
      replyTextProjection: { offset: 0, length: 1 },
      blocks: [{ t: 'p' as const, html: 'old partial answer' },
        { t: 'thinking' as const, content: 'reasoning', redacted: false }, { t: 'attach' as const, name: 'result.txt' }],
    })) }
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: { reply: 'final answer', turn_ref: 'turn-1', turn_outcome: 'visible_reply' } })
    expect(keeperThreads.value.sangsu?.[0]?.blocks).toEqual([
      { t: 'thinking', content: 'reasoning', redacted: false }, { t: 'attach', name: 'result.txt' },
      { t: 'p', html: 'final answer' },
    ])
  })
  it.each(['https://example.com/a.png', 'https://example.com/document'])('keeps final text projection idempotent for %s', (reply) => {
    assistantEntry()
    const details = { type: 'CUSTOM' as const, name: 'KEEPER_REPLY_DETAILS' as const,
      value: { reply, turn_ref: 'turn-1', turn_outcome: 'visible_reply' as const } }
    applyKeeperStreamEvent('sangsu', 'reply-1', details)
    const first = keeperThreads.value.sangsu?.[0]?.blocks
    applyKeeperStreamEvent('sangsu', 'reply-1', details)
    expect(keeperThreads.value.sangsu?.[0]?.blocks).toEqual(first)
  })
  it.each([
    ['committed answer', { t: 'p', html: 'committed answer' }],
    ['https://example.com/a.png', { t: 'image', src: 'https://example.com/a.png' }],
    ['https://example.com/document', { t: 'link', url: 'https://example.com/document', title: 'document' }],
  ])('preserves canonical body blocks when final details replay for %s', (reply, block) => {
    const entries = chatHistoryEntriesFromRest('sangsu', [{ id: 'reply-1', role: 'assistant', content: reply as string,
      ts: 1, blocks: [block] }])
    mergeServerHistoryEntries('sangsu', entries)
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: { reply: 'late differing reply', turn_ref: 'turn-1', turn_outcome: 'visible_reply' } })
    expect(keeperThreads.value.sangsu?.[0]?.text).toBe(reply)
    expect(keeperThreads.value.sangsu?.[0]?.blocks).toEqual([block])
  })
  it('releases canonical body authority when a checkpoint continues into a new attempt', () => {
    mergeServerHistoryEntries('sangsu', chatHistoryEntriesFromRest('sangsu', [{ id: 'reply-1', role: 'assistant',
      content: '', ts: 1, blocks: [{ t: 'status', kind: 'continuation_checkpoint' }] }]))
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CONTINUATION_CHECKPOINT',
      value: { message: 'checkpoint', request_id: 'request-1' } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_STARTED' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: null })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: { reply: 'new answer', turn_ref: 'turn-1', turn_outcome: 'visible_reply' } })
    expect(keeperThreads.value.sangsu?.[0]).toMatchObject({ text: 'new answer', blocks: [{ t: 'p', html: 'new answer' }] })
  })
  it('preserves visible reply whitespace and SKILL-prefixed prose across deltas', () => {
    assistantEntry()
    const chunks = ['    ', '첫 줄', '\n', 'SKILL', '.md 설명', '\n\n\n', '끝  ', '\n\n']
    for (const delta of chunks) {
      expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'TEXT_MESSAGE_CONTENT', delta,
      })).toBeNull()
    }
    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe(chunks.join(''))
    expect(entry?.rawText).toBe(chunks.join(''))
    const reply = '    완료\nSKILL.md 설명\n\n\n끝  \n'
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_REPLY_DETAILS',
      value: { reply, turn_ref: 'turn-1', turn_outcome: 'visible_reply' },
    })).toBeNull()
    const completed = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(completed?.text).toBe(reply)
    expect(completed?.rawText).toBe(reply)
  })

  it.each([
    ['whole', ['  hello world\n\t다음 줄  ']],
    ['split', ['  ', 'hello', ' ', 'world', '\n', '\t', '다음', ' ', '줄', '  ']],
  ])('preserves thinking whitespace for %s SSE payloads', (_label, chunks) => {
    assistantEntry()
    for (const delta of chunks) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM',
        name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta },
      })
    }
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_CONTENT_BLOCK_STOP',
      value: { index: 0 },
    })
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      { kind: 'think', text: '  hello world\n\t다음 줄  ', ts: expect.any(String), agentCoreBlockIndex: 0 },
    ])
  })

  it('drops owned thinking that arrives after its response stops', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_START',
      value: { content_generation: 2, stream_scope: 0, model: 'fixture' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'current', response: { content_generation: 2, stream_scope: 0 } },
    })
    _flushPendingKeeperStreamDeltasForTests()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_STOP',
      value: { content_generation: 2, stream_scope: 0 },
    })
    const stopped = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(stopped?.streamState).toBe('finalizing')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'stale', response: { content_generation: 2, stream_scope: 0 } },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'older', response: { content_generation: 1, stream_scope: 9 } },
    })
    _flushPendingKeeperStreamDeltasForTests()
    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.streamState).toBe('finalizing')
    expect(reply?.traceSteps).toEqual([
      { kind: 'think', text: 'current', ts: expect.any(String), agentCoreBlockIndex: 0,
        responseOwner: { content_generation: 2, stream_scope: 0 } },
    ])
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

  // An attempt failure is not the end of the turn. The bubble keeps streaming
  // through it and the next attempt's answer renders in the same bubble; the
  // protocol line stays in the entry's error until the operation's terminal
  // event, carrying the operation's provenance, clears it.
  it('keeps the bubble streaming through a stream timeout and renders the next attempt', () => {
    assistantEntry('kmsg-operation-1')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-timed-out' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-timed-out', delta: 'half an' })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_PROTOCOL_ERROR',
      value: { kind: 'sse_timeout', reason: 'no provider event within the liveness window' },
    })).toBeNull()

    const timedOut = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(timedOut?.delivery).toBe('streaming')
    expect(timedOut?.rawText).toBe('half an')
    expect(typeof timedOut?.error).toBe('string')

    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_RUNTIME_ATTEMPT_STARTED',
      value: null,
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_START', messageId: 'm-answer' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', messageId: 'm-answer', delta: 'the answer' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_END', messageId: 'm-answer' })
    applyKeeperStreamEvent(
      'sangsu',
      'reply-1',
      { type: 'RUN_FINISHED' },
      { kind: 'operation', operationId: 'kmsg-operation-1' },
    )

    const answered = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(answered?.text).toBe('the answer')
    expect(answered?.delivery).toBe('delivered')
    expect(answered?.error).toBeNull()
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
        because: 'process execution requires approval',
      },
    })).toBeNull()

    const pending = keeperToolApprovals.value.sangsu?.['call-approve-1']
    expect(pending).toBeDefined()
    expect(pending?.toolName).toBe('Execute')
    expect(pending?.question).toBe('Execute ls -la 를 실행할까요?')
    expect(pending?.because).toBe('process execution requires approval')
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
      operationDeliveryProvenance('kmsg-operation-1', 'terminal_result'),
    )
  })

  it('overlays partial delta usage onto the start snapshot instead of replacing it', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_STREAM_MESSAGE_START',
      value: {
        stream_scope: 4,
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
      value: { stream_scope: 4, stop_reason: 'end_turn', usage: { output_tokens: 510 } },
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
          'terminal_result',
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
      'terminal_result',
    ))?.text).toBe('')
    expect(entries.find(entry => isOperationDeliveryProvenance(
      entry.deliveryProvenance,
      'kmsg-operation-2',
      'terminal_result',
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
        'terminal_result',
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
        'terminal_result',
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
        'terminal_result',
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
        'terminal_result',
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
          'terminal_result',
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

  it('a persisted request failure terminal keeps a late operation event from reopening the operation', () => {
    // keeper-state normalizes a persisted request_failure row to a
    // system-role entry with terminal_result provenance. The operation it
    // terminated is finished: a delayed broadcast for the same operation
    // must be ignored, not appended as a fresh assistant bubble.
    const operationId = 'late-event-after-failure'
    appendThreadEntry('sangsu', {
      id: 'persisted-failure',
      role: 'system',
      source: 'direct_assistant',
      label: 'sangsu',
      text: 'REQUEST_FAILURE_DIAGNOSTIC',
      rawText: 'REQUEST_FAILURE_DIAGNOSTIC',
      timestamp: new Date().toISOString(),
      delivery: 'request_failure',
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'),
      details: null,
    })
    const before = [...(keeperThreads.value.sangsu ?? [])]
    const applied = applyKeeperOperationTurnEvent('sangsu', {
      operationId,
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'late fragment' },
    })
    const after = keeperThreads.value.sangsu ?? []
    expect(applied).toBe(null)
    expect(after.length).toBe(before.length)
    expect(after.every(entry => entry.role !== 'assistant' || entry.delivery !== 'sending'))
      .toBe(true)
    expect(after.some(entry => entry.id === 'persisted-failure'
      && entry.delivery === 'request_failure')).toBe(true)
  })

  it('a persisted request failure terminal keeps a late operation event from reopening the operation', () => {
    // keeper-state normalizes a persisted request_failure row to a
    // system-role entry with terminal_result provenance. The operation it
    // terminated is finished: a delayed broadcast for the same operation
    // must be ignored, not appended as a fresh assistant bubble.
    const operationId = 'late-event-after-failure'
    appendThreadEntry('sangsu', {
      id: 'persisted-failure',
      role: 'system',
      source: 'direct_assistant',
      label: 'sangsu',
      text: 'REQUEST_FAILURE_DIAGNOSTIC',
      rawText: 'REQUEST_FAILURE_DIAGNOSTIC',
      timestamp: new Date().toISOString(),
      delivery: 'request_failure',
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'),
      details: null,
    })
    const before = [...(keeperThreads.value.sangsu ?? [])]
    const applied = applyKeeperOperationTurnEvent('sangsu', {
      operationId,
      event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'late fragment' },
    })
    const after = keeperThreads.value.sangsu ?? []
    expect(applied).toBe(null)
    expect(after.length).toBe(before.length)
    expect(after.every(entry => entry.role !== 'assistant' || entry.delivery !== 'sending'))
      .toBe(true)
    expect(after.some(entry => entry.id === 'persisted-failure'
      && entry.delivery === 'request_failure')).toBe(true)
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
    expect(tool.deliveryProvenance).toBeNull()
    expect(tool.toolOwnerKey).toEqual({ kind: 'operation', operation_id: 'kmsg-tool-1' })
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
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey: { kind: 'operation', operation_id: 'kmsg-tool-1' }, executionId: 'exec-tc-1', ordinal: 0 } })
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
    expect(tool?.deliveryProvenance).toBeNull()
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
    expect(reply?.error).toContain('tool_start_duplicate_index')
    expect(reply?.rawText).not.toContain('[stream protocol]')
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
    expect(reply?.rawText).not.toContain('[stream protocol]')
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
    expect(thread.find(entry => entry.id === 'reply-1')?.error).toBeUndefined()
  })
})

describe('refused response events leave the entry unchanged', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
  })
  const custom = (name: string, value: unknown) => ({ type: 'CUSTOM', name, value }) as unknown as KeeperChatStreamEvent
  const header = (generation: number, extra: Record<string, unknown> = {}) => custom('KEEPER_STREAM_MESSAGE_START', {
    content_generation: generation, stream_scope: 0, provider_message_id: `provider-${generation}`, model: `model-${generation}`, ...extra,
  })
  const owner = (generation: number) => ({ content_generation: generation, stream_scope: 0 })
  const text = (delta: string, generation: number): KeeperChatStreamEvent => ({ type: 'TEXT_MESSAGE_CONTENT', delta, textResponse: owner(generation) })
  const finished = { type: 'RUN_FINISHED', runId: 'run-1' } as unknown as KeeperChatStreamEvent
  const entry = () => keeperThreads.value.sangsu![0]!
  const apply = (event: KeeperChatStreamEvent) => applyKeeperStreamEvent('sangsu', 'reply-1', event)

  it('keeps provider details when an older response header arrives', () => {
    assistantEntry()
    apply(header(5, { usage: { input_tokens: 7, output_tokens: 1 } }))
    const before = entry()
    expect(before.details).toMatchObject({ providerMessageId: 'provider-5', modelUsed: 'model-5' })
    apply(header(4, { usage: { input_tokens: 99 } }))
    expect(entry()).toEqual(before)
  })

  it('keeps provider details and activity when an older response reports its details', () => {
    assistantEntry()
    apply(header(5))
    const before = entry()
    apply(custom('KEEPER_STREAM_MESSAGE_DELTA', { content_generation: 4, stream_scope: 0, stop_reason: 'end_turn', usage: { input_tokens: 99 } }))
    expect(entry()).toEqual(before)
  })

  it('keeps a finished response unchanged against later lifecycle frames', () => {
    assistantEntry()
    apply(text('answer', 5))
    apply(finished)
    const before = entry()
    expect(before.responseState).toMatchObject({ phase: 'terminal' })
    const later: KeeperChatStreamEvent[] = [
      custom('KEEPER_RUNTIME_ATTEMPT_STARTED', null),
      { type: 'RUN_STARTED', runId: 'run-2' } as unknown as KeeperChatStreamEvent,
      custom('KEEPER_CONTINUATION_CHECKPOINT', { message: 'checkpoint' }),
      { type: 'TEXT_MESSAGE_START', messageId: 'm2', role: 'assistant' } as unknown as KeeperChatStreamEvent,
      { type: 'TEXT_MESSAGE_END', messageId: 'm2' } as unknown as KeeperChatStreamEvent,
      custom('KEEPER_STREAM_MESSAGE_STOP', owner(5)),
      header(6),
      text('LATE', 5),
    ]
    for (const event of later) {
      apply(event)
      expect(entry()).toEqual(before)
    }
  })

  it('ends admission for the response after RUN_ERROR', () => {
    assistantEntry()
    apply(text('a', 5))
    expect(apply({ type: 'RUN_ERROR', message: 'provider failed' } as unknown as KeeperChatStreamEvent)).toBe('provider failed')
    apply(text('b', 5))
    expect(entry().rawText).toBe('a')
  })

  it('refuses RUN_STARTED once a response is being observed', () => {
    assistantEntry()
    apply(text('a', 5))
    const before = entry()
    apply({ type: 'RUN_STARTED', runId: 'run-1' } as unknown as KeeperChatStreamEvent)
    expect(entry()).toEqual(before)
  })

  describe('when a newer response begins', () => {
    it.each([
      ['a header', header(5)],
      ['content activity alone', custom('KEEPER_MODEL_CONTENT_ACTIVITY', { generation: 5, stream_scope: 0, block_index: 0, channel: 'text', state: 'observed' })],
    ])('commits buffered reasoning under the response that produced it (%s)', (_label, newer) => {
      assistantEntry()
      apply(custom('KEEPER_THINKING_DELTA', { index: 0, delta: 'old thought', response: owner(4) }))
      expect(entry().traceSteps ?? []).toHaveLength(0)
      apply(newer)
      expect(entry().traceSteps).toMatchObject([{ kind: 'think', text: 'old thought', responseOwner: owner(4) }])
    })

    it('forgets the text block index of the response it replaces', () => {
      assistantEntry()
      apply(text('lead-in', 4))
      apply(custom('KEEPER_CONTENT_BLOCK_START', { index: 7, content_type: 'text' }))
      apply(header(5))
      apply(text('tail', 5))
      apply({ type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 0, toolCallName: 'Read' } as unknown as KeeperChatStreamEvent)
      const reply = keeperThreads.value.sangsu!.find(row => row.id === 'reply-1')
      const progress = reply?.traceSteps?.find(step => step.kind === 'progress')
      expect(progress).toMatchObject({ kind: 'progress', text: 'lead-intail' })
      expect(progress?.agentCoreBlockIndex).toBeUndefined()
    })

    it('accepts a message id that ended in the response it replaces', () => {
      assistantEntry()
      const unowned = (delta: string): KeeperChatStreamEvent => ({ type: 'TEXT_MESSAGE_CONTENT', messageId: 'm1', delta })
      apply(unowned('old'))
      apply({ type: 'TEXT_MESSAGE_END', messageId: 'm1' } as unknown as KeeperChatStreamEvent)
      apply(header(5))
      apply(unowned('new'))
      expect(entry().rawText).toBe('oldnew')
    })
  })
})

describe('late tool starts after a response ended', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
  })
  const operation = (sequence: number) => ({ kind: 'operation' as const, operationId: 'op-late', sequence })
  const lateStart = {
    type: 'TOOL_CALL_START', toolStreamScope: 0, toolCallBlockIndex: 0, toolCallId: 'provider-late', toolCallName: 'Read',
  } as unknown as KeeperChatStreamEvent

  it.each(['finished', 'failed'])('keeps the reply text and delivery of a %s response', ending => {
    assistantEntry('op-late')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'final answer' }, operation(1))
    if (ending === 'finished') {
      applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED', runId: 'run-1' } as unknown as KeeperChatStreamEvent, operation(2))
    } else {
      failKeeperStreamOperation('sangsu', 'reply-1', 'A Keeper stream frame does not match the protocol.')
    }
    const before = keeperThreads.value.sangsu!.find(row => row.id === 'reply-1')!
    expect(before.delivery).toBe(ending === 'finished' ? 'delivered' : 'error')
    applyKeeperStreamEvent('sangsu', 'reply-1', lateStart, operation(3))
    const after = keeperThreads.value.sangsu!.find(row => row.id === 'reply-1')!
    expect(after).toMatchObject({ text: 'final answer', rawText: 'final answer', delivery: before.delivery, streamState: before.streamState })
    expect(after.traceSteps?.some(step => step.kind === 'progress')).toBe(false)
    expect(after.traceSteps).toMatchObject([{ kind: 'tool', toolOccurrenceId: expect.any(String) }])
  })

  it('still moves the text of a running response into the turn timeline', () => {
    assistantEntry('op-late')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'lead-in' }, operation(1))
    applyKeeperStreamEvent('sangsu', 'reply-1', lateStart, operation(2))
    const after = keeperThreads.value.sangsu!.find(row => row.id === 'reply-1')!
    expect(after).toMatchObject({ text: '', delivery: 'streaming' })
    expect(after.traceSteps).toMatchObject([{ kind: 'progress', text: 'lead-in' }, { kind: 'tool' }])
  })
})

describe('owned text message replay', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    keeperThreads.value = {}
  })
  const owner = { content_generation: 5, stream_scope: 0 }
  const start = { type: 'TEXT_MESSAGE_START', messageId: 'm1', role: 'assistant' } as unknown as KeeperChatStreamEvent
  const content = (delta: string): KeeperChatStreamEvent => ({ type: 'TEXT_MESSAGE_CONTENT', messageId: 'm1', delta, textResponse: owner })
  const end = { type: 'TEXT_MESSAGE_END', messageId: 'm1' } as unknown as KeeperChatStreamEvent
  const text = () => keeperThreads.value.sangsu![0]!.rawText

  it('does not append an owned message again when its content is replayed without a sequence', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    applyKeeperStreamEvent('sangsu', 'reply-1', content('abc'))
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    applyKeeperStreamEvent('sangsu', 'reply-1', content('abc'))
    expect(text()).toBe('abc')
  })

  it.each([undefined, 3])('does not append an owned message again after its END (replay sequence %s)', sequence => {
    assistantEntry('op-1')
    const source = (n?: number) => ({ kind: 'operation' as const, operationId: 'op-1', ...(n === undefined ? {} : { sequence: n }) })
    applyKeeperStreamEvent('sangsu', 'reply-1', start, source(sequence === undefined ? undefined : 0))
    applyKeeperStreamEvent('sangsu', 'reply-1', content('abc'), source(sequence === undefined ? undefined : 1))
    applyKeeperStreamEvent('sangsu', 'reply-1', end, source(sequence === undefined ? undefined : 2))
    applyKeeperStreamEvent('sangsu', 'reply-1', content('abc'), source(sequence))
    expect(text()).toBe('abc')
  })

  it('marks an owned message finalizing at its END', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', start)
    applyKeeperStreamEvent('sangsu', 'reply-1', content('abc'))
    applyKeeperStreamEvent('sangsu', 'reply-1', end)
    expect(keeperThreads.value.sangsu![0]!.streamState).toBe('finalizing')
  })

  it('accepts the same message id again for a newer response', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', content('old'))
    applyKeeperStreamEvent('sangsu', 'reply-1', end)
    applyKeeperStreamEvent('sangsu', 'reply-1', { ...content('new'), textResponse: { content_generation: 6, stream_scope: 0 } } as KeeperChatStreamEvent)
    expect(text()).toBe('oldnew')
  })
})

describe('TEXT_MESSAGE_CONTENT response ownership', () => {
  beforeEach(() => {
    _resetKeeperStreamBuffersForTests()
    _resetLiveSendRequestOwnersForTests()
    _resetActiveKeeperStreamsForTests()
    keeperThreads.value = {}
  })

  const replyText = () => keeperThreads.value.sangsu
    ?.find(item => item.id === 'reply-1')?.text

  it('admits owned deltas and drops a delayed delta from an older response', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'fresh', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 1 },
    })
    expect(replyText()).toBe('fresh')
    // Same operation and message id: every messageId guard passes, so only
    // ownership can keep the superseded response's bytes out.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'stale', messageId: 'msg-1',
      textResponse: { content_generation: 4, stream_scope: 1 },
    })
    expect(replyText()).toBe('fresh')
  })

  it('demotes same-generation owners below a newer unobserved scope', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'fresh', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 0 },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'partial', messageId: 'msg-1',
      textStreamScope: 2,
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'stale', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 1 },
    })
    expect(replyText()).toBe('freshpartial')
  })

  it('retires the admitted owner to the stale floor when an attempt advances', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'failed attempt', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 0 },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED',
      value: { runtime_id: 'worker-2', attempt_index: 1 },
    })).toBeNull()
    // The delayed superseded delta shares the in-flight message id, so every
    // messageId guard passes; an equal identity is not "preceding" either —
    // only the retired floor rejects it.
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'late stale bytes', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 0 },
    })
    expect(replyText()).toBe('')
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'fresh attempt', messageId: 'msg-1',
      textResponse: { content_generation: 5, stream_scope: 1 },
    })
    expect(replyText()).toBe('fresh attempt')
  })

  it('preserves unowned bytes without admitting an owner', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: 'unowned', messageId: 'msg-1',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT', delta: ' then owned', messageId: 'msg-1',
      textResponse: { content_generation: 3, stream_scope: 0 },
    })
    expect(replyText()).toBe('unowned then owned')
  })
})
