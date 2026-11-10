import { afterEach, describe, expect, it, vi } from 'vitest'

const { fetchDashboardTools, setupObservationRefresh, stopRefresh } = vi.hoisted(() => ({
  fetchDashboardTools: vi.fn(async () => ({
    tools: [],
    keeper_waiting_inventory: { keepers: [] },
  })),
  setupObservationRefresh: vi.fn(),
  stopRefresh: vi.fn(),
}))

setupObservationRefresh.mockReturnValue(stopRefresh)

vi.mock('../../api', () => ({ fetchDashboardTools }))
vi.mock('../../lib/observation-refresh', () => ({ setupObservationRefresh }))

import { subscribeToolsAutoRefresh } from './tool-state'

let disposers: Array<() => void> = []

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  vi.clearAllMocks()
  setupObservationRefresh.mockReturnValue(stopRefresh)
})

describe('subscribeToolsAutoRefresh', () => {
  it('shares one observation subscription across multiple mounted consumers', () => {
    const first = subscribeToolsAutoRefresh()
    const second = subscribeToolsAutoRefresh()
    disposers = [first, second]

    expect(setupObservationRefresh).toHaveBeenCalledTimes(1)

    first()
    disposers = [second]
    expect(stopRefresh).not.toHaveBeenCalled()

    second()
    disposers = []
    expect(stopRefresh).toHaveBeenCalledTimes(1)
  })
})
