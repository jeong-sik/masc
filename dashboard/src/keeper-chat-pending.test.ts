import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  _clearPendingKeeperChatRequestsForTests,
  pendingKeeperChatRequestsForKeeper,
  removePendingKeeperChatRequest,
  upsertPendingKeeperChatRequest,
} from './keeper-chat-pending'

function runRef(runId: string, keeperName = 'echo') {
  return {
    runId,
    target: { kind: 'keeper', name: keeperName },
    capability: 'invoke_turn',
  } as const
}

describe('keeper chat pending request storage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    _clearPendingKeeperChatRequestsForTests()
  })

  afterEach(() => {
    vi.restoreAllMocks()
    _clearPendingKeeperChatRequestsForTests()
    window.localStorage.clear()
  })

  it('persists full run refs for repeated same-message sends', () => {
    const base = {
      message: 'status?',
      submittedAt: 1_780_000_000,
    }

    upsertPendingKeeperChatRequest({ ...base, runRef: runRef('kmsg_echo_1') })
    upsertPendingKeeperChatRequest({ ...base, runRef: runRef('kmsg_echo_2') })

    expect(pendingKeeperChatRequestsForKeeper('echo').map(request => request.runRef.runId)).toEqual([
      'kmsg_echo_1',
      'kmsg_echo_2',
    ])
    const stored = JSON.parse(
      window.localStorage.getItem('masc_keeper_chat_pending_requests_v2') ?? '[]',
    ) as Array<Record<string, unknown>>
    expect(stored[0]).toHaveProperty('run_ref')
    expect(stored[0]).not.toHaveProperty('requestId')
    expect(stored[0]).not.toHaveProperty('keeperName')

    removePendingKeeperChatRequest(runRef('kmsg_echo_1'))

    expect(pendingKeeperChatRequestsForKeeper('echo').map(request => request.runRef.runId)).toEqual([
      'kmsg_echo_2',
    ])
  })

  it('preserves the in-flight assistant draft for page reload recovery', () => {
    upsertPendingKeeperChatRequest({
      runRef: runRef('kmsg_echo_1'),
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
        runRef: runRef('kmsg_echo_1'),
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

  it('isolates the same run id across different Keeper targets', () => {
    const request = { message: 'status?', submittedAt: 1_780_000_000 }
    upsertPendingKeeperChatRequest({ ...request, runRef: runRef('shared-run', 'echo') })
    upsertPendingKeeperChatRequest({ ...request, runRef: runRef('shared-run', 'reviewer') })

    removePendingKeeperChatRequest(runRef('shared-run', 'echo'))

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect(pendingKeeperChatRequestsForKeeper('reviewer')).toEqual([
      expect.objectContaining({ runRef: runRef('shared-run', 'reviewer') }),
    ])
  })

  it('reports a malformed current-schema run ref instead of silently recovering it', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    window.localStorage.setItem('masc_keeper_chat_pending_requests_v2', JSON.stringify([{
      run_ref: { run_id: 'broken' },
      message: 'status?',
      submittedAt: 1_780_000_000,
    }]))

    expect(pendingKeeperChatRequestsForKeeper('echo')).toEqual([])
    expect(warn).toHaveBeenCalledWith(
      '[keeper-chat-pending] rejected invalid pending request at index 0',
    )
  })
})
