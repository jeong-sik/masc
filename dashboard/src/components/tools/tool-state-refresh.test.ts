import { afterEach, describe, expect, it, vi } from 'vitest'

const { fetchDashboardTools, setupVisibleAutoRefresh, stopRefresh } = vi.hoisted(() => ({
  fetchDashboardTools: vi.fn(async () => ({
    tools: [],
    keeper_waiting_inventory: { keepers: [] },
  })),
  setupVisibleAutoRefresh: vi.fn(),
  stopRefresh: vi.fn(),
}))

setupVisibleAutoRefresh.mockReturnValue(stopRefresh)

vi.mock('../../api', () => ({ fetchDashboardTools }))
vi.mock('../../lib/auto-refresh', () => ({ setupVisibleAutoRefresh }))
vi.mock('../../sse-store', () => ({ registerKeeperChatQueueRefresh: vi.fn() }))

import { subscribeToolsAutoRefresh } from './tool-state'

let disposers: Array<() => void> = []

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  vi.clearAllMocks()
  setupVisibleAutoRefresh.mockReturnValue(stopRefresh)
})

describe('subscribeToolsAutoRefresh', () => {
  it('shares one polling owner across multiple mounted consumers', () => {
    const first = subscribeToolsAutoRefresh()
    const second = subscribeToolsAutoRefresh()
    disposers = [first, second]

    expect(setupVisibleAutoRefresh).toHaveBeenCalledTimes(1)

    first()
    disposers = [second]
    expect(stopRefresh).not.toHaveBeenCalled()

    second()
    disposers = []
    expect(stopRefresh).toHaveBeenCalledTimes(1)
  })
})
