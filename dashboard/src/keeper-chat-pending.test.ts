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
})
