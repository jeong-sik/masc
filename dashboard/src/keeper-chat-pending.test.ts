import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  _clearPendingKeeperChatRequestsForTests,
  pendingKeeperChatRequestsForKeeper,
  removePendingKeeperChatRequest,
  upsertPendingKeeperChatRequest,
} from './keeper-chat-pending'

describe('keeper chat pending request storage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _clearPendingKeeperChatRequestsForTests()
  })

  afterEach(() => {
    _clearPendingKeeperChatRequestsForTests()
    window.localStorage.clear()
  })

  it('preserves distinct request ids for repeated same-message sends', () => {
    const base = {
      keeperName: 'echo',
      message: 'status?',
      submittedAt: 1_780_000_000,
    }

    upsertPendingKeeperChatRequest({ ...base, requestId: 'kmsg_echo_1' })
    upsertPendingKeeperChatRequest({ ...base, requestId: 'kmsg_echo_2' })

    expect(pendingKeeperChatRequestsForKeeper('echo').map(request => request.requestId)).toEqual([
      'kmsg_echo_1',
      'kmsg_echo_2',
    ])

    removePendingKeeperChatRequest('kmsg_echo_1')

    expect(pendingKeeperChatRequestsForKeeper('echo').map(request => request.requestId)).toEqual([
      'kmsg_echo_2',
    ])
  })

  it('preserves the in-flight assistant draft for page reload recovery', () => {
    upsertPendingKeeperChatRequest({
      requestId: 'kmsg_echo_1',
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
            name: 'keeper_board_list',
            toolCallId: 'tc-1',
            status: 'pending',
            args: '{"limit":5}',
          },
        ],
      },
    })

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([
      expect.objectContaining({
        requestId: 'kmsg_echo_1',
        assistantDraft: expect.objectContaining({
          text: '부분 응답',
          rawText: '부분 응답',
          delivery: 'streaming',
          streamState: 'thinking',
          traceSteps: [
            { kind: 'think', text: '상태 확인 중' },
            {
              kind: 'tool',
              name: 'keeper_board_list',
              toolCallId: 'tc-1',
              status: 'pending',
              args: '{"limit":5}',
            },
          ],
        }),
      }),
    ])
  })
})
