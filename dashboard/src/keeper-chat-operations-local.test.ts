import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearTrackedKeeperChatOperationsForTests,
  trackedKeeperChatOperationsForKeeper,
  removeTrackedKeeperChatOperation,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'

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
})
