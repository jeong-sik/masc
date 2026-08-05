import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  pushRefresh: null as ((keeperName: string) => void) | null,
  reconnectSubscribers: new Set<(count: number) => void>(),
}))

vi.mock('./api', () => ({
  fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory,
}))

vi.mock('./sse-store', () => ({
  registerKeeperWaitingInventoryRefresh: vi.fn((refresh: (keeperName: string) => void) => {
    mocks.pushRefresh = refresh
    return () => { mocks.pushRefresh = null }
  }),
}))

vi.mock('./dashboard-ws-state', () => ({
  dashboardWsReconnectCount: {
    value: 0,
    subscribe: (subscriber: (count: number) => void) => {
      mocks.reconnectSubscribers.add(subscriber)
      return () => mocks.reconnectSubscribers.delete(subscriber)
    },
  },
}))

import {
  keeperWaitingInventoryState,
  subscribeKeeperWaitingInventory,
} from './keeper-waiting-inventory-store'

afterEach(() => {
  vi.restoreAllMocks()
  mocks.fetchKeeperWaitingInventory.mockReset()
  mocks.pushRefresh = null
  mocks.reconnectSubscribers.clear()
})

describe('keeper waiting inventory store', () => {
  it('shares one scoped request and refreshes from push without installing a timer', async () => {
    let resolveFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementationOnce(() => new Promise(resolve => {
      resolveFirst = resolve
    }))
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: [] })
    const intervalSpy = vi.spyOn(window, 'setInterval')

    const stopLane = subscribeKeeperWaitingInventory('kidsnote')
    const stopConversation = subscribeKeeperWaitingInventory('kidsnote')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    expect(intervalSpy).not.toHaveBeenCalled()

    mocks.pushRefresh?.('rondo')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    mocks.pushRefresh?.('kidsnote')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)

    resolveFirst({ keepers: [] })
    await vi.waitFor(() => {
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2)
      expect(keeperWaitingInventoryState('kidsnote').loading).toBe(false)
    })

    const visibility = vi.spyOn(document, 'visibilityState', 'get')
    visibility.mockReturnValue('hidden')
    document.dispatchEvent(new Event('visibilitychange'))
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2)

    visibility.mockReturnValue('visible')
    document.dispatchEvent(new Event('visibilitychange'))
    await vi.waitFor(() => {
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3)
    })

    stopConversation()
    stopLane()
  })
})
