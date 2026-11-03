import { afterEach, describe, expect, it, vi } from 'vitest'
import type { KeeperWaitingInventoryChange } from './sse-store'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  pushRefresh: null as ((change: KeeperWaitingInventoryChange) => void) | null,
  readySubscribers: new Set<(ready: boolean) => void>(),
}))

vi.mock('./api', () => ({
  fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory,
}))

vi.mock('./sse-store', () => ({
  registerKeeperWaitingInventoryRefresh: vi.fn((refresh: (change: KeeperWaitingInventoryChange) => void) => {
    mocks.pushRefresh = refresh
    return () => { mocks.pushRefresh = null }
  }),
}))

vi.mock('./dashboard-ws-state', () => ({
  dashboardWsReady: {
    value: false,
    subscribe: (subscriber: (ready: boolean) => void) => {
      mocks.readySubscribers.add(subscriber)
      return () => mocks.readySubscribers.delete(subscriber)
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
  mocks.readySubscribers.clear()
})

describe('keeper waiting inventory store', () => {
  it('re-reads after the first websocket hello closes the initial observation gap', async () => {
    let releaseFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementationOnce(() => new Promise(resolve => {
      releaseFirst = resolve
    }))
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: [] })
    const stop = subscribeKeeperWaitingInventory('first-ready')
    try {
      for (const subscriber of mocks.readySubscribers) subscriber(true)
      releaseFirst({ keepers: [] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
      for (const subscriber of mocks.readySubscribers) subscriber(false)
      for (const subscriber of mocks.readySubscribers) subscriber(true)
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3))
    } finally {
      stop()
    }
  })

  it('shares one scoped request and refreshes from push without installing a timer', async () => {
    let resolveFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementationOnce(() => new Promise(resolve => {
      resolveFirst = resolve
    }))
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: [] })
    const intervalSpy = vi.spyOn(window, 'setInterval')

    const stopLane = subscribeKeeperWaitingInventory('exampleorg')
    const stopConversation = subscribeKeeperWaitingInventory('exampleorg')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    expect(intervalSpy).not.toHaveBeenCalled()

    mocks.pushRefresh?.({ scope: 'keeper', keeperName: 'rondo' })
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    mocks.pushRefresh?.({ scope: 'keeper', keeperName: 'exampleorg' })
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)

    resolveFirst({ keepers: [] })
    await vi.waitFor(() => {
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2)
      expect(keeperWaitingInventoryState('exampleorg').loading).toBe(false)
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

  it('refreshes all subscribed keepers after a workspace change, including a trailing read', async () => {
    let releaseFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementation((name: string) => {
      const count = mocks.fetchKeeperWaitingInventory.mock.calls.filter(([value]) => value === name).length
      if (name === 'alpha' && count === 1) {
        return new Promise(resolve => { releaseFirst = resolve })
      }
      return Promise.resolve({ keepers: [] })
    })

    const stopAlpha = subscribeKeeperWaitingInventory('alpha')
    const stopBeta = subscribeKeeperWaitingInventory('beta')
    try {
      await vi.waitFor(() => expect(keeperWaitingInventoryState('beta').loading).toBe(false))
      mocks.pushRefresh?.({ scope: 'workspace' })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3))
      expect(mocks.fetchKeeperWaitingInventory.mock.calls.filter(([name]) => name === 'alpha')).toHaveLength(1)
      releaseFirst({ keepers: [] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(4))
      expect(mocks.fetchKeeperWaitingInventory.mock.calls.filter(([name]) => name === 'alpha')).toHaveLength(2)
      expect(mocks.fetchKeeperWaitingInventory.mock.calls.filter(([name]) => name === 'beta')).toHaveLength(2)
    } finally {
      stopAlpha()
      stopBeta()
    }
  })
})
