import { effect, untracked } from '@preact/signals'
import { setStoredToken, clearStoredToken } from './api/core'
import { captureToolObservations } from './keeper-tool-observations'

import type { KeeperChatStreamEvent } from './lib/keeper-chat-stream-contract'
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
} from './keeper-state'
import { keeperThreads, keeperToolApprovals } from './keeper-state'
import {
  KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS,
  _flushPendingKeeperStreamDeltasForTests,
  _resetKeeperStreamBuffersForTests,
  abortKeeperThreadMessage,
  applyKeeperOperationTurnEvent,
  applyKeeperAutonomousTurnEvent,
  applyKeeperStreamEvent,
} from './keeper-stream'
import { parseSSEMessage, KeeperChatStreamEventSchema } from './schemas/sse'
import {
  operationDeliveryProvenance,
  toolCallDeliveryProvenance,
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
      ? { deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result') }
      : {}),
    details: null,
  })
}


function requiredFixture<T>(value: T | undefined): T {
  if (value === undefined) throw new Error('Expected fixture state to exist')
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
    const recoveredOwner = entry().responseState
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_RUNTIME_ATTEMPT_STARTED', value: { runtime_id: 'claude', attempt_index: 0 },
    })
    expect(entry().text).toBe('answer')
    expect(entry().responseState).toBe(recoveredOwner)
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
    const owner = { content_generation: 4, stream_scope: 2 }
    const thinking = (delta: string): KeeperChatStreamEvent => ({
      type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta, response: owner },
    })
    const source = (sequence: number) => ({ kind: 'operation' as const, operationId: 'op-1', sequence })
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    owner.content_generation = 99
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps?.[0]).toMatchObject({ responseOwner: { content_generation: 4, stream_scope: 2 } })
    owner.content_generation = 4
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).responseState).toMatchObject({ lastSequence: 10 })
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps).toMatchObject([{ kind: 'think', text: 'first', responseOwner: owner }])
    // In-memory batching is lost on reload; the restored entry is authoritative.
    _resetKeeperStreamBuffersForTests()
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking('first'), source(10))
    applyKeeperStreamEvent('sangsu', 'reply-1', thinking(' second'), source(11))
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).traceSteps).toMatchObject([{ kind: 'think', text: 'first second' }])
  })

  it('keeps reused reasoning block indices separate across owned responses', () => {
    assistantEntry()
    for (const generation of [4, 5]) {
      applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
        value: { index: 0, delta: `generation ${generation}`, response: { content_generation: generation, stream_scope: 0 } },
      }, { kind: 'operation', operationId: 'op-1', sequence: generation })
    }
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

  it('does not consume the valid frame sequence when a broadcast payload is malformed', () => {
    assistantEntry()
    const diagnostic = parseSSEMessage({ type: 'keeper_chat_operation_event', name: 'sangsu', operation_id: 'op-1', seq: 12,
      ag_ui_event: { type: 'TEXT_MESSAGE_CONTENT', delta: 123 } })
    expect(diagnostic?.seq).toBeUndefined()
    const event = KeeperChatStreamEventSchema.safeParse(diagnostic?.ag_ui_event)
    if (event.success) applyKeeperStreamEvent('sangsu', 'reply-1', event.data,
      { kind: 'operation', operationId: 'op-1', sequence: diagnostic?.seq })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'valid counterpart' },
      { kind: 'operation', operationId: 'op-1', sequence: 12 })
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).rawText).toBe('valid counterpart')
    expect(requiredFixture(requiredFixture(keeperThreads.value.sangsu)[0]).responseState).toMatchObject({ lastSequence: 12 })
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
      value: { ...result.value, toolCallId: 'provider-b' } }, source)).toContain('provider correlation conflicts')
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
      expect(result).toContain('provider correlation conflicts')
      expect(requiredFixture(keeperThreads.value.sangsu).filter(row => row.role === 'tool')).toHaveLength(2)
      expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.id === planned.id)?.executionId).toBeUndefined()
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

  it.each([false, true])('keeps trace lanes separate through late tool convergence (wrapper=%s)', wrapper => {
    const operationId = 'trace-tool-convergence'
    _clearTrackedKeeperChatOperationsForTests()
    upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'input', submittedAt: 1 })
    assistantEntry(operationId)
    const source = { kind: 'operation' as const, operationId }
    let sequence = 0
    const send = (event: KeeperChatStreamEvent) => wrapper
      ? applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: sequence++, event })
      : applyKeeperStreamEvent('sangsu', 'reply-1', event, source)
    const owner = { content_generation: 1, stream_scope: 0 }
    send({ type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: owner })
    send({ type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'provided reasoning', response: owner } })
    _flushPendingKeeperStreamDeltasForTests()
    const published = [{ kind: 'think' as const, text: '', contentWithheld: true }]
    mergeServerHistoryEntries('sangsu', chatHistoryEntriesFromRest('sangsu', [{ id: 'reply-1', role: 'assistant',
      source: 'direct_assistant', content: 'canonical answer', ts: 1,
      delivery_provenance_status: 'valid', delivery_provenance: operationDeliveryProvenance(operationId, 'terminal_result'),
      blocks: [{ t: 'trace', trace: published }] }]))
    appendThreadEntry('sangsu', { id: 'other-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'other input answer', rawText: 'other input answer', delivery: 'streaming', streamState: 'thinking',
      deliveryProvenance: operationDeliveryProvenance('other-operation', 'terminal_result'),
      traceSteps: [{ kind: 'think', text: 'other reasoning' }] })
    send({ type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read' })
    send({ type: 'CUSTOM', name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...toolOccurrence(), executionId: 'execution' } })
    const observedTool = requiredFixture(requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool'))
    const canonicalReply = requiredFixture(chatHistoryEntriesFromRest('sangsu', [{ id: 'reply-1', role: 'assistant',
      source: 'direct_assistant', content: 'canonical answer', ts: 1,
      delivery_provenance_status: 'valid', delivery_provenance: operationDeliveryProvenance(operationId, 'terminal_result'),
      blocks: [{ t: 'trace', trace: published }] }])[0])
    mergeServerHistoryEntries('sangsu', [canonicalReply, { ...observedTool, id: 'canonical-tool', delivery: 'history',
      toolOccurrence: undefined, toolOwnerKey: undefined,
      deliveryProvenance: toolCallDeliveryProvenance(operationDeliveryProvenance(operationId, 'terminal_result'), 'execution', 0) }])
    send({ type: 'CUSTOM', name: 'KEEPER_TOOL_TRANSCRIPT_COMMITTED',
      value: { deliveryKey: { kind: 'operation', operation_id: operationId }, executionId: 'execution', ordinal: 0 } })
    const rows = requiredFixture(keeperThreads.value.sangsu)
    const reply = requiredFixture(rows.find(row => row.id === 'reply-1'))
    expect(reply.publishedTraceSteps).toEqual(published)
    expect(reply.traceSteps?.filter(step => step.kind === 'think')).toMatchObject([{ text: 'provided reasoning' }])
    expect(reply.traceSteps?.filter(step => step.kind === 'tool')).toMatchObject([{ toolOccurrenceId: 'canonical-tool' }])
    expect(rows.filter(row => row.role === 'tool')).toHaveLength(1)
    expect(rows.find(row => row.id === 'other-reply')).toMatchObject({ text: 'other input answer',
      traceSteps: [{ kind: 'think', text: 'other reasoning' }] })
    expect(rows.find(row => row.id === 'other-reply')?.publishedTraceSteps).toBeUndefined()
    const draft = requiredFixture(trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft)
    expect(draft.publishedTraceSteps).toEqual(published)
    expect(draft.traceSteps?.filter(step => step.kind === 'think')).toMatchObject([{ text: 'provided reasoning' }])
    expect(draft.traceSteps?.filter(step => step.kind === 'tool')).toMatchObject([{ toolOccurrenceId: 'canonical-tool' }])
    _clearTrackedKeeperChatOperationsForTests()
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
      value: { ...toolOccurrence(), executionId: 'must-not-bind' } } })).toContain('quarantined')
    expect(requiredFixture(keeperThreads.value.sangsu).find(row => row.role === 'tool')).toMatchObject({ toolOccurrenceQuarantined: true, delivery: 'error' })
    expect(requiredFixture(keeperThreads.value.sangsu).some(row => row.executionId === 'must-not-bind')).toBe(false)
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
        value: { ...occurrence, executionId: 'must-not-rebind' } } })).toContain('quarantined')
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
        approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'call-1',
        tool_call_name: 'Execute',
        args: '{}',
        question: 'run it?',
        because: 'policy',
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
  it('projects actual approval frames through the strict decoder into approval state', () => {
    assistantEntry()
    const opening = KeeperChatStreamEventSchema.parse({
      type: 'CUSTOM', threadId: 'keeper-consumer:sangsu', runId: 'run-1', timestamp: 1_712_000_000, name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: { approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'decoded-call', tool_call_name: 'Execute',
        args: '{}', question: 'Run?', because: 'policy' },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', opening)).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']?.settled).toBe(false)
    const closing = KeeperChatStreamEventSchema.parse({
      type: 'CUSTOM', threadId: 'keeper-consumer:sangsu', runId: 'run-1', timestamp: 1_712_000_000, name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'decoded-call', outcome: 'approve' },
    })
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', closing)).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']?.settled).toBe(true)
  })

  it('does not let a displaced admission settle a reused provider call', () => {
    assistantEntry()
    const firstId = '019a0000-0000-7000-8000-000000000001'
    const nextId = '019a0000-0000-7000-8000-000000000002'
    for (const approval_id of [firstId, nextId]) {
      expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
        type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
        value: { approval_id, tool_call_id: 'provider-reused',
          tool_call_name: 'Execute', args: '{}', question: 'Run?', because: 'policy' },
      })).toBeNull()
    }
    const current = keeperToolApprovals.value.sangsu?.[nextId]
    expect(current?.approvalId).toBe(nextId)
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: firstId, tool_call_id: 'provider-reused', outcome: 'displaced' },
    })).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.[nextId]).toBe(current)
    expect(current?.settled).toBe(false)
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: nextId, tool_call_id: 'provider-reused', outcome: 'approve' },
    })).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.[nextId]?.settled).toBe(true)
  })

  it('does not reopen a settled admission when its opening is replayed', () => {
    assistantEntry()
    const opening = {
      type: 'CUSTOM' as const, name: 'KEEPER_TOOL_APPROVAL_REQUESTED' as const,
      value: { approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'replayed-call', tool_call_name: 'Execute', args: '{}',
        question: 'Run?', because: 'policy' },
    }
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', opening)).toBeNull()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: opening.value.approval_id, tool_call_id: 'replayed-call', outcome: 'approve' },
    })).toBeNull()
    const terminal = keeperToolApprovals.value.sangsu?.[opening.value.approval_id]
    expect(terminal?.settled).toBe(true)
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', opening)).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.[opening.value.approval_id]).toBe(terminal)
  })

  it('retains an unseen terminal before a delayed opening', () => {
    assistantEntry()
    const approval_id = '019a0000-0000-7000-8000-000000000003'
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id, tool_call_id: 'unseen-call', outcome: 'timed_out' },
    })).toBeNull()
    const terminal = keeperToolApprovals.value.sangsu?.[approval_id]
    expect(terminal?.settled).toBe(true)
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: { approval_id, tool_call_id: 'unseen-call', tool_call_name: 'Execute',
        args: '{}', question: 'Run?', because: 'policy' },
    })).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.[approval_id]).toBe(terminal)
  })

  it('mints a pending approval row on KEEPER_TOOL_APPROVAL_REQUESTED', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_REQUESTED',
      value: {
        approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'call-approve-1',
        tool_call_name: 'Execute',
        args: '{"argv":["ls","-la"]}',
        question: 'Execute ls -la 를 실행할까요?',
        because: 'process execution requires approval',
      },
    })).toBeNull()

    const pending = keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']
    if (!pending || pending.settled) throw new Error('Expected pending approval')
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
        approval_id: '019a0000-0000-7000-8000-000000000001',
        tool_call_id: 'call-settle-1',
        tool_call_name: 'Execute',
        args: '{}',
        question: 'run it?',
        because: 'policy',
      },
    })
    expect(keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']).toBeDefined()

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: '019a0000-0000-7000-8000-000000000001', tool_call_id: 'call-settle-1', outcome: 'Approved' },
    })).toBeNull()
    expect(keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']?.settled).toBe(true)
    expect(keeperToolApprovals.value.sangsu?.['019a0000-0000-7000-8000-000000000001']?.answeredOutcome).toBe('Approved')
  })

  it('keeps the stream alive when a settle names a call this view never drew', () => {
    assistantEntry()
    // A wait answered from another window settles without a local REQUESTED;
    // the drop must be a no-op, not a stream-ending error.
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: '019a0000-0000-7000-8000-000000000001', tool_call_id: 'call-unknown-1', outcome: 'Denied' },
    })).toBeNull()
    expect(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')).toBeDefined()
  })

  it('does not let late acceptance reopen a completed response', () => {
    assistantEntry('kmsg-operation-1')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'completed answer' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'RUN_FINISHED' })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(before.responseState).toMatchObject({ phase: 'terminal' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'kmsg-operation-1', state: 'Queued', queued_count: 1 },
    })
    const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(after.delivery).toBe(before.delivery)
    expect(after.streamState).toBe(before.streamState)
    expect(after.rawText).toBe(before.rawText)
    expect(after.responseState).toMatchObject({ phase: 'terminal' })
  })

  it('keeps active output when acceptance arrives after content', () => {
    assistantEntry('owned-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TEXT_MESSAGE_CONTENT', delta: 'active output' })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(before.delivery).toBe('streaming')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'owned-operation', state: 'Queued', queued_count: 1 } })
    const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(after.delivery).toBe(before.delivery)
    expect(after.streamState).toBe(before.streamState)
    expect(after.rawText).toBe(before.rawText)
  })

  it('refuses acceptance belonging to a different operation', () => {
    assistantEntry('owned-operation')
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'foreign-operation', state: 'Queued', queued_count: 1 } })
    const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(after.deliveryProvenance).toEqual(before.deliveryProvenance)
    expect(after.delivery).toBe(before.delivery)
    expect(after.streamState).toBe(before.streamState)
  })

  it('preserves admitted reasoning while its buffered preview has not flushed', () => {
    assistantEntry('reasoning-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'exposed reasoning', response: { content_generation: 1, stream_scope: 0 } } })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(before.responseState).toMatchObject({ current: { content_generation: 1, stream_scope: 0 } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'reasoning-operation', state: 'Queued', queued_count: 1 } })
    const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(after.delivery).toBe(before.delivery)
    expect(after.streamState).toBe(before.streamState)
    _flushPendingKeeperStreamDeltasForTests()
    expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')?.traceSteps).toMatchObject([{ kind: 'think', text: 'exposed reasoning' }])
  })

  it('does not bind an unowned response to an acceptance outside its operation source', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'foreign-operation', state: 'Queued', queued_count: 1 } },
      { kind: 'operation', operationId: 'source-operation', sequence: 1 })
    const entry = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(entry.deliveryProvenance).toBeUndefined()
    expect(entry.delivery).toBe('sending')
  })

  it('does not turn an autonomous journal response into an accepted user operation', () => {
    applyKeeperAutonomousTurnEvent('sangsu', 'autonomous-turn', 1,
      { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
        value: { operation_id: 'foreign-operation', state: 'Queued', queued_count: 1 } })
    const entry = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.turnRef === 'autonomous-turn'))
    expect(entry.deliveryProvenance).toBeNull()
    expect(entry.delivery).toBe('sending')
    expect(entry.source).toBe('autonomous_turn')
  })

  it('binds an unowned response when acceptance matches its operation source', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'source-operation', state: 'Queued', queued_count: 1 } },
      { kind: 'operation', operationId: 'source-operation', sequence: 1 })
    const entry = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(entry.deliveryProvenance).toEqual(operationDeliveryProvenance('source-operation', 'terminal_result'))
    expect(entry.delivery).toBe('queued')
  })

  const foreignOperationEvents: KeeperChatStreamEvent[] = [
    { type: 'TEXT_MESSAGE_CONTENT', delta: 'foreign speech' },
    { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: 'foreign reasoning', response: { content_generation: 3, stream_scope: 0 } } },
    { type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'foreign-tool' },
  ]
  it.each(foreignOperationEvents)('refuses a foreign operation frame before publication or sequence advancement: %j', event => {
    assistantEntry('owned-operation')
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    applyKeeperStreamEvent('sangsu', 'reply-1', event,
      { kind: 'operation', operationId: 'foreign-operation', sequence: 99 })
    _flushPendingKeeperStreamDeltasForTests()
    expect(keeperThreads.value.sangsu).toEqual([before])
  })

  it('refuses a frame from another autonomous turn', () => {
    applyKeeperAutonomousTurnEvent('sangsu', 'owned-turn', 1, { type: 'RUN_STARTED' })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.turnRef === 'owned-turn'))
    applyKeeperStreamEvent('sangsu', before.id, { type: 'TEXT_MESSAGE_CONTENT', delta: 'foreign speech' },
      { kind: 'autonomous', turnRef: 'foreign-turn', sequence: 99 })
    expect(keeperThreads.value.sangsu).toEqual([before])
  })

  it('retains exact continuation provenance for frames from its owning operation', () => {
    appendThreadEntry('sangsu', { id: 'continuation', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: '', rawText: '', timestamp: null, delivery: 'sending', streamState: 'opening', details: null,
      deliveryProvenance: { delivery_key: { kind: 'operation_native', operation_id: 'owned-operation', continuation_id: 'continuation-id' }, transcript_slot: { kind: 'terminal_result' } } })
    applyKeeperStreamEvent('sangsu', 'continuation', { type: 'TEXT_MESSAGE_CONTENT', delta: 'owned speech' },
      { kind: 'operation', operationId: 'owned-operation', sequence: 1 })
    const entry = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'continuation'))
    expect(entry.rawText).toBe('owned speech')
    expect(entry.deliveryProvenance?.delivery_key).toEqual({ kind: 'operation_native', operation_id: 'owned-operation', continuation_id: 'continuation-id' })
  })

  it('refuses operation events targeting an autonomous response without operation provenance', () => {
    applyKeeperAutonomousTurnEvent('sangsu', 'owned-turn', 1, { type: 'RUN_STARTED' })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.turnRef === 'owned-turn'))
    applyKeeperStreamEvent('sangsu', before.id, { type: 'TEXT_MESSAGE_CONTENT', delta: 'foreign operation speech' },
      { kind: 'operation', operationId: 'foreign-operation', sequence: 99 })
    expect(keeperThreads.value.sangsu).toEqual([before])
  })

  it.each(['user', 'tool'] as const)('does not apply assistant stream frames to a %s row', role => {
    appendThreadEntry('sangsu', { id: 'authored-row', role, source: role === 'user' ? 'direct_user' : 'tool_result',
      label: role, text: 'original authored bytes', rawText: 'original authored bytes', timestamp: null,
      delivery: 'delivered', streamState: null, details: null })
    const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'authored-row'))
    applyKeeperStreamEvent('sangsu', 'authored-row', { type: 'TEXT_MESSAGE_CONTENT', delta: 'assistant output' })
    expect(keeperThreads.value.sangsu).toEqual([before])
  })

  it.each(['credential', 'operation', 'target role'] as const)('revokes buffered thinking after %s replacement', replacement => {
    assistantEntry('original-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'original reasoning', response: { content_generation: 1, stream_scope: 0 } } })
    try {
      if (replacement === 'credential') setStoredToken('synthetic-buffer-replacement')
      else {
        keeperThreads.value = {}
        if (replacement === 'operation') assistantEntry('replacement-operation')
        else appendThreadEntry('sangsu', { id: 'reply-1', role: 'user', source: 'direct_user', label: 'user', text: 'user bytes', rawText: 'user bytes', timestamp: null, delivery: 'delivered', streamState: null, details: null })
      }
      const before = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
      _flushPendingKeeperStreamDeltasForTests()
      expect(keeperThreads.value.sangsu).toEqual([before])
    } finally { if (replacement === 'credential') clearStoredToken() }
  })

  it('does not restore old activity onto a response replaced by a thinking observer', () => {
    assistantEntry('original-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'observed reasoning', response: { content_generation: 1, stream_scope: 0 } } },
      { kind: 'operation', operationId: 'original-operation', observationOnly: true })
    let armed = true
    const release = effect(() => {
      const current = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
      if (armed && current?.traceSteps?.some(step => step.kind === 'think')) {
        armed = false
        untracked(() => { keeperThreads.value = { sangsu: [{ ...current,
          deliveryProvenance: operationDeliveryProvenance('replacement-operation', 'terminal_result'),
          delivery: 'queued', streamState: null, text: 'replacement', rawText: 'replacement', traceSteps: [],
        }] } })
      }
    })
    try {
      _flushPendingKeeperStreamDeltasForTests()
      const after = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
      expect(after.deliveryProvenance).toEqual(operationDeliveryProvenance('replacement-operation', 'terminal_result'))
      expect(after.delivery).toBe('queued')
      expect(after.streamState).toBeNull()
      expect(after.rawText).toBe('replacement')
    } finally { release() }
  })

  it('preserves previous-generation reasoning under the newer metadata response activity', () => {
    assistantEntry('owned-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'previous response reasoning', response: { content_generation: 1, stream_scope: 0 } } })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_DELTA',
      value: { content_generation: 2, stream_scope: 1, usage: { output_tokens: 1 } } })
    const entry = requiredFixture(keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1'))
    expect(entry.responseState).toMatchObject({ current: { content_generation: 2, stream_scope: 1 } })
    expect(entry.traceSteps).toMatchObject([{ kind: 'think', text: 'previous response reasoning', responseOwner: { content_generation: 1, stream_scope: 0 } }])
    expect(entry.streamState).toBe('opening')
    expect(entry.delivery).toBe('streaming')
  })

  it('does not restore old activity after an observer advances the same producer response owner', () => {
    assistantEntry('owned-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'observed reasoning', response: { content_generation: 1, stream_scope: 0 } } },
      { kind: 'operation', operationId: 'owned-operation', observationOnly: true })
    let armed = true
    const release = effect(() => {
      const current = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
      if (armed && current?.traceSteps?.some(step => step.kind === 'think')) {
        armed = false
        untracked(() => applyKeeperStreamEvent('sangsu', 'reply-1', {
          type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START',
          value: { content_generation: 2, stream_scope: 1 },
        }))
      }
    })
    try {
      _flushPendingKeeperStreamDeltasForTests()
      const entry = requiredFixture(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1'))
      expect(entry.responseState).toMatchObject({ current: { content_generation: 2, stream_scope: 1 } })
      expect(entry.traceSteps).toMatchObject([{ kind: 'think', text: 'observed reasoning', responseOwner: { content_generation: 1, stream_scope: 0 } }])
      expect(entry.delivery).toBe('streaming')
      expect(entry.streamState).toBe('opening')
    } finally { release() }
  })

  it('keeps tool activity started by an observer of same-owner reasoning', () => {
    assistantEntry('owned-operation')
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: 'observed reasoning', response: { content_generation: 1, stream_scope: 0 } } },
      { kind: 'operation', operationId: 'owned-operation', observationOnly: true })
    let armed = true
    const release = effect(() => {
      const current = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
      if (armed && current?.traceSteps?.some(step => step.kind === 'think')) {
        armed = false
        untracked(() => applyKeeperStreamEvent('sangsu', 'reply-1', {
          type: 'TOOL_CALL_START', ...toolOccurrence(), toolCallName: 'Read', toolCallId: 'observer-tool',
        }))
      }
    })
    try {
      _flushPendingKeeperStreamDeltasForTests()
      const entry = requiredFixture(keeperThreads.value.sangsu?.find(item => item.id === 'reply-1'))
      expect(entry.delivery).toBe('streaming')
      expect(entry.streamState).toBe('streaming')
      expect(entry.traceSteps).toMatchObject([{ kind: 'think', text: 'observed reasoning' }, { kind: 'tool', name: 'Read', status: 'pending' }])
    } finally { release() }
  })

  it('does not grant temporary activity to unowned autonomous reasoning observations', () => {
    applyKeeperAutonomousTurnEvent('sangsu', 'autonomous-observation', 1, { type: 'RUN_STARTED' })
    applyKeeperAutonomousTurnEvent('sangsu', 'autonomous-observation', 2, {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: { content_generation: 1, stream_scope: 0 },
    })
    const states: Array<string | null | undefined> = []
    const release = effect(() => {
      const entry = keeperThreads.value.sangsu?.find(item => item.turnRef === 'autonomous-observation')
      if (entry?.traceSteps?.some(step => step.kind === 'think')) states.push(entry.streamState)
    })
    try {
      applyKeeperAutonomousTurnEvent('sangsu', 'autonomous-observation', 3, {
        type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: 'unowned exposed reasoning' },
      })
      const entry = requiredFixture(keeperThreads.value.sangsu?.find(item => item.turnRef === 'autonomous-observation'))
      expect(entry.traceSteps).toMatchObject([{ kind: 'think', text: 'unowned exposed reasoning' }])
      expect(states.length).toBeGreaterThan(0)
      expect(states).not.toContain('thinking')
      expect(entry.streamState).toBe('opening')
    } finally { release() }
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

it('recovers late operation response metadata without reopening canonical history', () => {
  keeperThreads.value = {}
  _resetLiveSendRequestOwnersForTests()
  _resetKeeperStreamBuffersForTests()
  const operationId = 'historical-response-metadata'
  _clearTrackedKeeperChatOperationsForTests()
  upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'request', submittedAt: 1 })
  appendThreadEntry('sangsu', {
    id: 'canonical-metadata', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
    text: 'canonical answer', delivery: 'history', streamState: null,
    blocks: [{ t: 'p', html: 'canonical answer' }], replyBlockSource: 'canonical_body',
    deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null,
  })
  applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 0,
    event: { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: {
      content_generation: 1, stream_scope: 0, model: 'observed-model', provider_message_id: 'provider-id',
      usage: { input_tokens: 3, output_tokens: 6, cost_usd: 0 } } } })
  expect(trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft).toMatchObject({
    text: 'canonical answer', delivery: 'history', streamState: null,
    details: { modelUsed: 'observed-model', providerMessageId: 'provider-id', costUsd: 0,
      usage: { inputTokens: 3, outputTokens: 6, costUsd: 0 } },
  })
  applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 1,
    event: { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_DELTA', value: {
      content_generation: 1, stream_scope: 0, usage: { input_tokens: 3, output_tokens: 7 } } } })
  expect(keeperThreads.value.sangsu?.find(entry => entry.id === 'canonical-metadata')).toMatchObject({
    text: 'canonical answer', delivery: 'history', streamState: null, replyBlockSource: 'canonical_body',
    blocks: [{ t: 'p', html: 'canonical answer' }],
    details: { modelUsed: 'observed-model', providerMessageId: 'provider-id',
      usage: { inputTokens: 3, outputTokens: 7, costUsd: 0 } },
  })
  expect(trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft).toMatchObject({
    text: 'canonical answer', delivery: 'history', streamState: null,
  })
})

it('retains late owned operation reasoning without reopening canonical history', () => {
  keeperThreads.value = {}
  _resetLiveSendRequestOwnersForTests()
  _resetKeeperStreamBuffersForTests()
  _clearTrackedKeeperChatOperationsForTests()
  const operationId = 'late-reasoning'
  upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'request', submittedAt: 1 })
  appendThreadEntry('sangsu', { id: operationId, role: 'assistant', source: 'direct_assistant', label: 'sangsu',
    text: 'canonical answer', delivery: 'history', streamState: null,
    deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
  applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 0, event: {
    type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: { content_generation: 1, stream_scope: 0 } } })
  applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 1, event: {
    type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: 'exposed reasoning',
      response: { content_generation: 1, stream_scope: 0 } } } })
  const draft = trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft
  expect(draft).toMatchObject({ text: 'canonical answer', delivery: 'history', streamState: null,
    responseState: { lastSequence: 1 }, traceSteps: [{ kind: 'think', text: 'exposed reasoning' }] })
})

it('preserves canonical delivery through delayed historical operation reasoning previews', () => {
  vi.useFakeTimers()
  try {
    keeperThreads.value = {}
    _resetLiveSendRequestOwnersForTests()
    _resetKeeperStreamBuffersForTests()
    _clearTrackedKeeperChatOperationsForTests()
    const operationId = 'historical-reasoning-preview'
    const owner = { content_generation: 1, stream_scope: 0 }
    upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'request', submittedAt: 1 })
    appendThreadEntry('sangsu', { id: operationId, role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: 'canonical answer', delivery: 'history', streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
    applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 0, event: {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: owner } })
    const think = (delta: string) => applyKeeperOperationTurnEvent('sangsu', { operationId, event: {
      type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta, response: owner } } })
    think('reasoning prefix\n')
    expect(vi.getTimerCount()).toBeGreaterThan(0)
    vi.advanceTimersByTime(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
    expect(trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft).toMatchObject({
      text: 'canonical answer', delivery: 'history', streamState: null,
      traceSteps: [{ kind: 'think', text: 'reasoning prefix\n' }],
    })
    think('suffix')
    expect(vi.getTimerCount()).toBeGreaterThan(0)
    vi.advanceTimersByTime(KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
    applyKeeperOperationTurnEvent('sangsu', { operationId, sequence: 1, event: {
      type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP', value: owner } })
    expect(trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft).toMatchObject({
      text: 'canonical answer', delivery: 'history', streamState: null,
      responseState: { lastSequence: 1 }, traceSteps: [{ kind: 'think', text: 'reasoning prefix\nsuffix' }],
    })
  } finally {
    _resetKeeperStreamBuffersForTests()
    vi.useRealTimers()
  }
})

it('recovers historical operation Saying at a tool boundary without copying the final tail', () => {
  keeperThreads.value = {}
  _resetLiveSendRequestOwnersForTests()
  _resetKeeperStreamBuffersForTests()
  _clearTrackedKeeperChatOperationsForTests()
  const operationId = 'historical-saying'
  const owner = { content_generation: 1, stream_scope: 0 }
  upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'request', submittedAt: 1 })
  appendThreadEntry('sangsu', { id: operationId, role: 'assistant', source: 'direct_assistant', label: 'sangsu',
    text: 'canonical answer', delivery: 'history', streamState: null,
    deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
  const send = (sequence: number, event: KeeperChatStreamEvent) =>
    applyKeeperOperationTurnEvent('sangsu', { operationId, sequence, event })
  send(0, { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: owner })
  send(1, { type: 'TEXT_MESSAGE_CONTENT', delta: 'checking ', textResponse: owner })
  send(2, { type: 'TEXT_MESSAGE_CONTENT', delta: 'the result', textResponse: owner })
  const saved = trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft
  expect(saved?.producerSayingReplay?.text).toBe('checking the result')
  _resetKeeperStreamBuffersForTests()
  keeperThreads.value = { sangsu: [{ ...keeperThreads.value.sangsu![0]!,
    producerSayingReplay: saved?.producerSayingReplay, producerTraceBoundary: saved?.producerTraceBoundary,
    responseState: saved?.responseState }] }
  send(3, { type: 'TOOL_CALL_START', toolCallId: 'tool', toolCallName: 'Read', ...toolOccurrence() })
  send(4, { type: 'TEXT_MESSAGE_CONTENT', delta: 'canonical answer', textResponse: owner })
  send(5, { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, delta: '', response: owner } })
  send(6, { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 0, response: owner } })
  send(7, { type: 'CUSTOM', name: 'KEEPER_THINKING_DELTA', value: { index: 1, delta: 'unowned observation' } })
  send(8, { type: 'RUN_FINISHED' })
  send(9, { type: 'TEXT_MESSAGE_CONTENT', delta: 'late tail', textResponse: owner })
  const draft = trackedKeeperChatOperationsForKeeper('sangsu')[0]?.assistantDraft
  expect(draft).toMatchObject({ text: 'canonical answer', delivery: 'history', streamState: null,
    responseState: { phase: 'terminal', lastSequence: 9 } })
  expect(draft?.traceSteps?.filter(step => step.kind === 'progress').map(step => step.text)).toEqual(['checking the result'])
  expect(draft?.traceSteps?.filter(step => step.kind === 'think').map(step => step.text)).toContain('unowned observation')
})

it('isolates persisted metadata for interleaved operations sharing provider identifiers', () => {
  keeperThreads.value = {}
  _resetLiveSendRequestOwnersForTests()
  _resetKeeperStreamBuffersForTests()
  _clearTrackedKeeperChatOperationsForTests()
  for (const operationId of ['operation-a', 'operation-b']) {
    upsertTrackedKeeperChatOperation({ operationId, keeperName: 'sangsu', message: 'same input', submittedAt: 1 })
    appendThreadEntry('sangsu', { id: operationId, role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: `canonical ${operationId}`, delivery: 'history', streamState: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'), details: null })
  }
  const send = (operationId: string, sequence: number, event: KeeperChatStreamEvent) =>
    applyKeeperOperationTurnEvent('sangsu', { operationId, sequence, event })
  const start = (generation: number, scope: number, model: string): KeeperChatStreamEvent => ({
    type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_START', value: {
      content_generation: generation, stream_scope: scope, provider_message_id: 'shared-provider-id', model,
      usage: { input_tokens: generation, output_tokens: 2, cost_usd: 0 } } })
  send('operation-a', 0, start(1, 0, 'first-a'))
  send('operation-b', 0, start(1, 0, 'only-b'))
  send('operation-a', 1, { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_STOP',
    value: { content_generation: 1, stream_scope: 0 } })
  send('operation-a', 2, start(2, 1, 'latest-a'))
  send('operation-b', 1, { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_DELTA',
    value: { content_generation: 1, stream_scope: 0, usage: { output_tokens: 8 } } })
  send('operation-a', 3, start(1, 99, 'stale-a'))
  send('operation-a', 4, { type: 'CUSTOM', name: 'KEEPER_STREAM_MESSAGE_DELTA',
    value: { content_generation: 2, stream_scope: 1, usage: { output_tokens: 9 } } })
  send('operation-b', 0, start(99, 99, 'replayed-b'))
  const stored = trackedKeeperChatOperationsForKeeper('sangsu')
  for (const [operationId, model, input, output, sequence] of [
    ['operation-a', 'latest-a', 2, 9, 4], ['operation-b', 'only-b', 1, 8, 1],
  ] as const) {
    expect(stored.find(operation => operation.operationId === operationId)?.assistantDraft).toMatchObject({
      text: `canonical ${operationId}`, delivery: 'history', streamState: null,
      responseState: { lastSequence: sequence }, details: { modelUsed: model, providerMessageId: 'shared-provider-id',
        costUsd: 0, usage: { inputTokens: input, outputTokens: output, costUsd: 0 } },
    })
  }
})
