import { operationDeliveryProvenance, toolCallDeliveryProvenance } from './keeper-delivery-provenance'
import type { TrackedKeeperChatAssistantDraft } from './keeper-chat-operations-local'
import { initialKeeperResponseState } from './lib/keeper-response-state'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearTrackedKeeperChatOperationsForTests,
  trackedKeeperChatOperationsForKeeper,
  removeTrackedKeeperChatOperation,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'


function requiredFixture<T>(value: T | undefined): T {
  if (value === undefined) throw new Error('Expected fixture state to exist')
  return value
}

describe('keeper chat operation tracking', () => {
  it.each(['terminal', 'future-boundary'] as const)('quarantines contradictory stored speech: %s', kind => {
    upsertTrackedKeeperChatOperation({ operationId: 'contradictory', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'canonical answer', rawText: 'canonical answer', delivery: 'history', streamState: null,
        responseState: { ...initialKeeperResponseState, phase: kind === 'terminal' ? 'terminal' : 'running', lastSequence: 2 },
        producerTraceBoundary: kind === 'future-boundary' ? 3 : 2,
        producerSayingReplay: { text: 'untrusted pending', timestamp: 1, owner: null, scope: null } } })
    const draft = trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft
    expect(draft).toMatchObject({ responseState: { kind: 'unavailable' }, delivery: 'error' })
    expect(draft?.producerSayingReplay).toBeUndefined()
    expect(draft?.producerTraceBoundary).toBeUndefined()
  })
  it('restores frontend response details through repeated durable draft reads', () => {
    const details = {
      traceId: 'trace', turnRef: 'turn', providerMessageId: '', modelUsed: 'observed-model',
      stopReason: 'end_turn', latencyMs: 0, costUsd: 0, replyText: '  reply  ',
      usage: { inputTokens: 3, outputTokens: 7, totalTokens: 10,
        cacheCreationInputTokens: 0, cacheReadInputTokens: 2, costUsd: 0 },
      turnOutcome: 'external_effect_completed' as const,
      externalEffectTarget: { kind: 'slack' as const, channelId: 'channel', threadTs: 'thread' },
    }
    upsertTrackedKeeperChatOperation({ operationId: 'metadata', keeperName: 'echo', message: 'request', submittedAt: 1,
      assistantDraft: { text: 'reply', rawText: 'reply', delivery: 'history', streamState: null,
        details: { ...details, rawPayload: { privatePayload: 'excluded' } } } })
    for (let read = 0; read < 2; read++) {
      const stored = requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0])
      expect(stored.assistantDraft?.details).toEqual(details)
      upsertTrackedKeeperChatOperation(stored)
    }
  })
  beforeEach(() => {
    window.localStorage.clear()
    _clearTrackedKeeperChatOperationsForTests()
  })

  afterEach(() => {
    _clearTrackedKeeperChatOperationsForTests()
    window.localStorage.clear()
  })

  it.each([false, true])('reports corrupt published trace without losing the original reply (mixed=%s)', mixed => {
    window.localStorage.setItem('masc_keeper_chat_operations_v1', JSON.stringify([{
      operationId: 'corrupt-trace', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'canonical answer', rawText: 'canonical answer', delivery: 'history', streamState: null,
        publishedTraceSteps: [...(mixed ? [{ kind: 'think', text: 'valid published reasoning' }] : []), { kind: 'think', text: 42 }],
        traceSteps: [{ kind: 'think', text: 'provided reasoning' }] },
    }]))
    const draft = trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft
    expect(draft).toMatchObject({ text: 'canonical answer', delivery: 'error', responseState: { kind: 'unavailable' },
      traceSteps: [{ kind: 'think', text: 'provided reasoning' }] })
    expect(draft?.error).toBeTruthy()
    expect(draft?.publishedTraceSteps).toBeUndefined()
  })

  it('preserves distinct operation ids for repeated same-message sends', () => {
    const base = {
      keeperName: 'echo',
      message: 'status?',
      submittedAt: 1_780_000_000,
    }

    upsertTrackedKeeperChatOperation({ ...base, operationId: 'kmsg_echo_1' })
    upsertTrackedKeeperChatOperation({ ...base, operationId: 'kmsg_echo_2' })

    expect(trackedKeeperChatOperationsForKeeper('echo').map(request => request.operationId)).toEqual([
      'kmsg_echo_1',
      'kmsg_echo_2',
    ])

    removeTrackedKeeperChatOperation('kmsg_echo_1')

    expect(trackedKeeperChatOperationsForKeeper('echo').map(request => request.operationId)).toEqual([
      'kmsg_echo_2',
    ])
  })

  it('preserves authored message text through storage and rejects blank messages', () => {
    const message = '    들여쓰기\nSKILL.md 설명\n\n\n끝  \n'
    const base = { keeperName: 'echo', submittedAt: 1_780_000_000 }
    upsertTrackedKeeperChatOperation({ ...base, operationId: 'kmsg-1', message })
    upsertTrackedKeeperChatOperation({ ...base, operationId: 'kmsg-2', message: 'next' })
    upsertTrackedKeeperChatOperation({ ...base, operationId: 'kmsg-blank', message: ' \n' })
    const restored = trackedKeeperChatOperationsForKeeper('echo')
    expect(restored.map(operation => operation.operationId)).toEqual(['kmsg-1', 'kmsg-2'])
    expect(restored[0]?.message).toBe(message)
  })

  it('preserves the in-flight assistant draft for page reload recovery', () => {
    upsertTrackedKeeperChatOperation({
      operationId: 'kmsg_echo_1',
      keeperName: 'echo',
      message: 'status?',
      submittedAt: 1_780_000_000,
      assistantDraft: {
        text: '부분 응답',
        rawText: '부분 응답',
        delivery: 'streaming',
        streamState: 'thinking',
        traceSteps: [
          { kind: 'think', text: '상태 확인 중' },
          {
            kind: 'tool',
            name: 'masc_board_list',
            toolCallId: 'tc-1',
            executionId: 'exec-1',
            toolOccurrenceId: 'tool-delivery-reply-1-0',
            status: 'pending',
            args: '{"limit":5}',
          },
        ],
      },
    })

    expect(trackedKeeperChatOperationsForKeeper('echo')).toEqual([
      expect.objectContaining({
        operationId: 'kmsg_echo_1',
        assistantDraft: expect.objectContaining({
          text: '부분 응답',
          rawText: '부분 응답',
          delivery: 'streaming',
          streamState: 'thinking',
          traceSteps: [
            { kind: 'think', text: '상태 확인 중' },
            {
              kind: 'tool',
              name: 'masc_board_list',
              toolCallId: 'tc-1',
              executionId: 'exec-1',
              toolOccurrenceId: 'tool-delivery-reply-1-0',
              status: 'pending',
              args: '{"limit":5}',
            },
          ],
        }),
      }),
    ])
  })
  it('retains the newer applied journal snapshot across older observer and receipt writes', () => {
    const request = { operationId: 'shared-op', keeperName: 'echo', message: 'original input', submittedAt: 1_780_000_000 }
    const draft = (sequence: number, text: string) => ({
      text, rawText: text, delivery: 'streaming' as const, streamState: 'streaming' as const,
      responseState: { ...initialKeeperResponseState, lastSequence: sequence },
    })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft(12, 'newest') })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft(11, 'old observer') })
    upsertTrackedKeeperChatOperation(request)
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft).toMatchObject({
      rawText: 'newest', responseState: { lastSequence: 12 },
    })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft(13, 'next event') })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft).toMatchObject({
      rawText: 'next event', responseState: { lastSequence: 13 },
    })
  })

  it.each(['delivered', 'no_reply', 'cancelled', 'error', 'request_failure', 'interrupted', 'timeout'] as const)(
    'preserves stored %s delivery instead of reopening the request queue', delivery => {
      upsertTrackedKeeperChatOperation({ operationId: 'terminal-draft', keeperName: 'echo', message: 'input', submittedAt: 1,
        assistantDraft: { text: 'authored bytes', rawText: 'authored bytes', delivery, streamState: null,
          responseState: { ...initialKeeperResponseState, phase: 'terminal' } } })
      expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft).toMatchObject({
        delivery, streamState: null, rawText: 'authored bytes', responseState: { phase: 'terminal' },
      })
    },
  )

  it('persists normal planned-to-bound tool transition without erasing quarantine authority', () => {
    const request = { operationId: 'binding-tools', keeperName: 'echo', message: 'input', submittedAt: 1 }
    const parent = operationDeliveryProvenance(request.operationId, 'terminal_result')
    const tool = { id: 'tool', label: 'Read', text: '', toolCallId: 'provider-a', delivery: 'streaming' as const,
      toolOccurrence: { kind: 'identified' as const, streamScope: 1, blockIndex: 0 },
      toolOwnerKey: parent.delivery_key, deliveryProvenance: null }
    const draft: TrackedKeeperChatAssistantDraft = { text: 'body', rawText: 'body', delivery: 'streaming', streamState: null,
      toolObservations: { kind: 'known', entries: [tool] } }
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, toolObservations: { kind: 'known', entries: [
      { ...tool, executionId: 'execution', deliveryProvenance: toolCallDeliveryProvenance(parent, 'execution', 0) },
    ] } } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.toolObservations).toMatchObject({ kind: 'known', entries: [{ executionId: 'execution' }] })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, toolObservations: { kind: 'known', entries: [
      { ...tool, toolCallId: undefined, executionId: 'execution', deliveryProvenance: toolCallDeliveryProvenance(parent, 'execution', 0) },
    ] } } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.toolObservations).toMatchObject({ kind: 'known', entries: [{ toolCallId: 'provider-a' }] })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, toolObservations: { kind: 'known', entries: [] } } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.toolObservations).toEqual({ kind: 'unavailable' })
  })

  it('retains unavailable tool authority through receipt-only and assistant-only writes', () => {
    const request = { operationId: 'unavailable-tools', keeperName: 'echo', message: 'input', submittedAt: 1 }
    const draft = { text: 'authored', rawText: 'authored', delivery: 'streaming' as const, streamState: null,
      toolObservations: { kind: 'unavailable' as const } }
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft })
    upsertTrackedKeeperChatOperation(request)
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft?.toolObservations).toEqual({ kind: 'unavailable' })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, toolObservations: { kind: 'known', entries: [] } } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0]).assistantDraft).toMatchObject({ rawText: 'authored', toolObservations: { kind: 'unavailable' } })
  })

  it('quarantines unknown delivery without turning it into queued or losing authored bytes', () => {
    upsertTrackedKeeperChatOperation({ operationId: 'bad-delivery', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'preserve', rawText: 'preserve', delivery: 'unrecognized' as never, streamState: null } })
    expect(requiredFixture(trackedKeeperChatOperationsForKeeper('echo')[0])).toMatchObject({ message: 'input', assistantDraft: {
      rawText: 'preserve', delivery: 'error', responseState: { kind: 'unavailable' },
    } })
  })

})
