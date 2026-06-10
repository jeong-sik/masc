import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { callMcpTool } = vi.hoisted(() => ({ callMcpTool: vi.fn() }))
const { runOperatorAction } = vi.hoisted(() => ({ runOperatorAction: vi.fn() }))
const { invalidateDashboardCache, refreshDashboard } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))
const { cancelQueuedKeeperMessage, fetchKeeperChatHistory, streamKeeperMessage } = vi.hoisted(() => ({
  cancelQueuedKeeperMessage: vi.fn(async () => undefined),
  fetchKeeperChatHistory: vi.fn(),
  streamKeeperMessage: vi.fn(),
}))

vi.mock('./api/mcp', () => ({ callMcpTool }))
vi.mock('./api/core', () => ({ runOperatorAction }))
vi.mock('./api/keeper', () => ({
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  streamKeeperMessage,
}))
vi.mock('./store', () => ({ invalidateDashboardCache, refreshDashboard }))

import { keeperThreads, keeperActionErrors } from './keeper-state'
import {
  _resetChatHydrationForTests,
  hydrateKeeperChatHistory,
  noteKeeperChatAppended,
  sendKeeperThreadMessage,
} from './keeper-actions'
import type { KeeperChatStreamEvent } from './api'

describe('noteKeeperChatAppended', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('skips keepers whose transcript was never hydrated', async () => {
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()
    expect(fetchKeeperChatHistory).not.toHaveBeenCalled()
  })

  it('debounces a burst of appends into one forced refetch', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])
    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)

    noteKeeperChatAppended('echo')
    noteKeeperChatAppended('echo')
    noteKeeperChatAppended('echo')
    await vi.runAllTimersAsync()

    // One additional fetch despite the once-per-keeper hydration guard
    // (force) and despite three push events (debounce).
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
  })
})

describe('hydrateKeeperChatHistory', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    _resetChatHydrationForTests()
    fetchKeeperChatHistory.mockReset()
  })

  it('merges the server transcript into the thread', async () => {
    fetchKeeperChatHistory.mockResolvedValue([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
      { role: 'assistant', content: 'hello there', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')

    const thread = keeperThreads.value.echo ?? []
    expect(thread).toHaveLength(2)
    expect(thread[0]?.delivery).toBe('history')
    expect(thread[1]?.role).toBe('assistant')
  })

  it('fetches only once per keeper per page lifetime', async () => {
    fetchKeeperChatHistory.mockResolvedValue([])

    await hydrateKeeperChatHistory('echo')
    await hydrateKeeperChatHistory('echo')

    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(1)
  })

  it('allows a retry after a failed fetch', async () => {
    fetchKeeperChatHistory.mockRejectedValueOnce(new Error('HTTP 502'))
    fetchKeeperChatHistory.mockResolvedValueOnce([
      { role: 'user', content: 'hi', ts: 1_780_000_000 },
    ])

    await hydrateKeeperChatHistory('echo')
    expect(keeperActionErrors.value.echo).toContain('이전 대화 불러오기 실패')

    await hydrateKeeperChatHistory('echo')
    expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
    expect(keeperThreads.value.echo).toHaveLength(1)
  })
})

describe('sendKeeperThreadMessage stream outcome', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    streamKeeperMessage.mockReset()
    refreshDashboard.mockClear()
    invalidateDashboardCache.mockClear()
  })

  function emitting(events: KeeperChatStreamEvent[], terminal: boolean) {
    return async (
      _name: string,
      _message: string,
      opts: { onEvent: (event: KeeperChatStreamEvent) => void },
    ) => {
      for (const event of events) opts.onEvent(event)
      return { terminal }
    }
  }

  it('marks the reply interrupted when the stream ends without a terminal event', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_START' },
      { type: 'TEXT_MESSAGE_CONTENT', delta: '부분 응답' },
    ], false))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('interrupted')
    expect(reply?.text).toContain('부분 응답')
    expect(reply?.error).toContain('끊겼습니다')
    expect(keeperActionErrors.value.echo).toContain('끊겼습니다')
  })

  it('delivers normally on RUN_FINISHED and does not force a dashboard refresh', async () => {
    streamKeeperMessage.mockImplementation(emitting([
      { type: 'RUN_STARTED' },
      { type: 'TEXT_MESSAGE_START' },
      { type: 'TEXT_MESSAGE_CONTENT', delta: '완료된 응답' },
      { type: 'TEXT_MESSAGE_END' },
      { type: 'RUN_FINISHED' },
    ], true))

    await sendKeeperThreadMessage('echo', '진행 상황?')

    const reply = (keeperThreads.value.echo ?? []).find(entry => entry.role === 'assistant')
    expect(reply?.delivery).toBe('delivered')
    expect(reply?.text).toContain('완료된 응답')
    // Regression guard: the per-message force refresh re-rendered the
    // whole dashboard after every chat send (user-visible "refresh").
    expect(refreshDashboard).not.toHaveBeenCalled()
    expect(invalidateDashboardCache).not.toHaveBeenCalled()
  })
})
