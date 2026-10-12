import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearTrackedKeeperChatOperationsForTests,
  trackedKeeperChatOperationsForKeeper,
  removeTrackedKeeperChatOperation,
  upsertTrackedKeeperChatOperation,
  type TrackedKeeperChatAssistantDraft,
} from './keeper-chat-operations-local'
import { initialKeeperResponseState } from './lib/keeper-response-state'

describe('keeper chat operation tracking', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _clearTrackedKeeperChatOperationsForTests()
  })

  afterEach(() => {
    _clearTrackedKeeperChatOperationsForTests()
    window.localStorage.clear()
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
  it('preserves the running attempt identity for retry gating after reload', () => {
    upsertTrackedKeeperChatOperation({ operationId: 'attempt-identity', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'partial', rawText: 'partial', delivery: 'streaming', streamState: 'retrying',
        runtimeAttempt: { runtimeId: 'claude', index: 1 } } })
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.runtimeAttempt).toEqual({
      runtimeId: 'claude', index: 1,
    })
    window.localStorage.setItem('masc_keeper_chat_operations_v1', JSON.stringify([{ operationId: 'attempt-identity',
      keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: { text: 'partial', rawText: 'partial', delivery: 'streaming', streamState: 'retrying',
        runtimeAttempt: { runtimeId: 'claude', index: -1 } } }]))
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.runtimeAttempt).toBeUndefined()
  })

  it.each(['foreign owner', 'duplicate', 'unknown channel', 'negative index', 'extra field'] as const)(
    'quarantines invalid stored content inventory: %s', kind => {
      const activity = { generation: 1, stream_scope: 0, block_index: 0, channel: 'thinking', state: 'ended' }
      const invalid = kind === 'duplicate' ? [activity, activity] : [{ ...activity,
        ...(kind === 'foreign owner' ? { generation: 2 } : {}),
        ...(kind === 'unknown channel' ? { channel: 'tool' } : {}),
        ...(kind === 'negative index' ? { block_index: -1 } : {}),
        ...(kind === 'extra field' ? { text: 'not metadata' } : {}),
      }]
      const owner = { content_generation: 1, stream_scope: 0 }
      upsertTrackedKeeperChatOperation({ operationId: 'content', keeperName: 'echo', message: 'input', submittedAt: 1,
        assistantDraft: { text: 'preserved answer', rawText: 'preserved answer', delivery: 'streaming', streamState: 'waiting',
          modelContentActivity: invalid as never,
          responseState: { ...initialKeeperResponseState, floor: owner, current: owner, lastSequence: 2 } } })
      expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft).toMatchObject({
        text: 'preserved answer', responseState: { kind: 'unavailable' }, delivery: 'error', streamState: null,
      })
    },
  )

  it('preserves closed content when a same-response draft omits or reopens its inventory', () => {
    const owner = { content_generation: 1, stream_scope: 0 }
    const activity = { generation: 1, stream_scope: 0, block_index: 0, channel: 'thinking' as const, state: 'ended' as const }
    const draft: TrackedKeeperChatAssistantDraft = { text: '', rawText: '', delivery: 'streaming', streamState: 'waiting',
      responseState: { ...initialKeeperResponseState, floor: owner, current: owner, lastSequence: 2 } }
    const request = { operationId: 'content', keeperName: 'echo', message: 'input', submittedAt: 1 }
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, modelContentActivity: [activity] } })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: draft })
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.modelContentActivity).toEqual([activity])
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft,
      streamState: 'thinking', modelContentActivity: [{ ...activity, state: 'observed' }] } })
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.modelContentActivity).toEqual([activity])
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.streamState).toBe('waiting')
  })

  it('does not carry closed occurrences into a newer response', () => {
    const request = { operationId: 'content', keeperName: 'echo', message: 'input', submittedAt: 1 }
    for (const generation of [1, 2]) {
      const owner = { content_generation: generation, stream_scope: 0 }
      upsertTrackedKeeperChatOperation({ ...request, assistantDraft: {
        text: '', rawText: '', delivery: 'streaming', streamState: generation === 1 ? 'waiting' : 'thinking',
        responseState: { ...initialKeeperResponseState, floor: owner, current: owner, lastSequence: generation },
        modelContentActivity: [{ generation, stream_scope: 0, block_index: 0, channel: 'thinking',
          state: generation === 1 ? 'ended' : 'observed' }],
      } })
    }
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.modelContentActivity).toMatchObject([
      { generation: 2, state: 'observed' },
    ])
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft?.modelContentActivity).toHaveLength(1)
  })

  it('restores an omitted open occurrence in stored order and derives its phase', () => {
    const owner = { content_generation: 1, stream_scope: 0 }
    const think = { generation: 1, stream_scope: 0, block_index: 0, channel: 'thinking' as const, state: 'observed' as const }
    const text = { generation: 1, stream_scope: 0, block_index: 1, channel: 'text' as const, state: 'observed' as const }
    const request = { operationId: 'content-order', keeperName: 'echo', message: 'input', submittedAt: 1 }
    const draft = { text: '', rawText: '', delivery: 'streaming' as const,
      responseState: { ...initialKeeperResponseState, floor: owner, current: owner, lastSequence: 2 } }
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, streamState: 'streaming', modelContentActivity: [think, text] } })
    upsertTrackedKeeperChatOperation({ ...request, assistantDraft: { ...draft, streamState: 'thinking', modelContentActivity: [think] } })
    const stored = trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft
    expect(stored?.modelContentActivity).toEqual([think, text])
    expect(stored?.streamState).toBe('streaming')
  })

  it('rejects open content without a current response owner but keeps ended tombstones', () => {
    const owner = { content_generation: 1, stream_scope: 0 }
    const draftFor = (state: 'observed' | 'ended') => ({ text: '', rawText: '', delivery: 'streaming' as const, streamState: 'waiting' as const,
      responseState: { ...initialKeeperResponseState, floor: owner, current: null, lastSequence: 2 },
      modelContentActivity: [{ generation: 1, stream_scope: 0, block_index: 0, channel: 'thinking' as const, state }] })
    upsertTrackedKeeperChatOperation({ operationId: 'content-ownerless', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: draftFor('observed') })
    expect(trackedKeeperChatOperationsForKeeper('echo')[0]?.assistantDraft).toMatchObject({
      responseState: { kind: 'unavailable' }, delivery: 'error', streamState: null,
    })
    upsertTrackedKeeperChatOperation({ operationId: 'content-tombstone', keeperName: 'echo', message: 'input', submittedAt: 1,
      assistantDraft: draftFor('ended') })
    const tombstone = trackedKeeperChatOperationsForKeeper('echo').find(request => request.operationId === 'content-tombstone')
    expect(tombstone?.assistantDraft?.responseState).toMatchObject({ kind: 'known' })
    expect(tombstone?.assistantDraft?.modelContentActivity).toHaveLength(1)
  })
})
