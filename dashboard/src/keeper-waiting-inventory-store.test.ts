import { clearStoredToken, currentStoredTokenRevision, setStoredToken } from './api/core'
import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  pushRefresh: null as ((keeperName: string) => void) | null,
  reconnectSubscribers: new Set<(count: number) => void>(),
}))

vi.mock('./api', () => ({
  fetchKeeperWaitingInventory: (name: string, opts: { onAdmission?: (admission: { path: string; authRevision: number }) => void }) => {
    const pending = mocks.fetchKeeperWaitingInventory(name)
    return Promise.resolve().then(() => {
      opts.onAdmission?.({ path: `/api/v1/keepers/${name}/waiting-inventory`, authRevision: currentStoredTokenRevision() })
      return pending
    })
  },
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
  refreshKeeperWaitingInventory,
  subscribeKeeperWaitingInventory,
} from './keeper-waiting-inventory-store'

afterEach(() => {
  clearStoredToken()
  vi.restoreAllMocks()
  mocks.fetchKeeperWaitingInventory.mockReset()
  mocks.pushRefresh = null
  mocks.reconnectSubscribers.clear()
})

describe('keeper waiting inventory store', () => {
  it.each(['resolve', 'reject'] as const)('ignores an old authentication inventory result (%s)', async outcome => {
    setStoredToken('fixture-old')
    let finish!: (value: { keepers: never[] }) => void
    let fail!: (error: Error) => void
    mocks.fetchKeeperWaitingInventory.mockReturnValueOnce(new Promise((resolve, reject) => { finish = resolve; fail = reject }))
    const reading = refreshKeeperWaitingInventory('auth-result')
    await Promise.resolve()
    await Promise.resolve()
    setStoredToken('fixture-new')
    if (outcome === 'resolve') finish({ keepers: [] })
    else fail(new Error('old inventory failed'))
    await reading
    expect(keeperWaitingInventoryState('auth-result')).toMatchObject({ inventory: null, ready: false, loading: false, error: null })
  })

  it('admits a replacement read while the older authentication request is pending', async () => {
    setStoredToken('fixture-old')
    let oldFinish!: (value: { keepers: never[] }) => void
    let newFinish!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockReturnValueOnce(new Promise(resolve => { oldFinish = resolve }))
      .mockReturnValueOnce(new Promise(resolve => { newFinish = resolve }))
    const old = refreshKeeperWaitingInventory('replacement')
    await Promise.resolve()
    await Promise.resolve()
    setStoredToken('fixture-new')
    const current = refreshKeeperWaitingInventory('replacement')
    await Promise.resolve()
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2)
    oldFinish({ keepers: [] })
    await old
    expect(refreshKeeperWaitingInventory('replacement')).toBe(current)
    newFinish({ keepers: [] })
    await current
    expect(keeperWaitingInventoryState('replacement').ready).toBe(true)
  })

  it('withdraws the cached inventory and refreshes mounted subscribers on authentication replacement', async () => {
    setStoredToken('fixture-old')
    mocks.fetchKeeperWaitingInventory.mockResolvedValueOnce({ keepers: [] })
    const stop = subscribeKeeperWaitingInventory('cached')
    try {
      await vi.waitFor(() => expect(keeperWaitingInventoryState('cached').ready).toBe(true))
      mocks.fetchKeeperWaitingInventory.mockReturnValueOnce(new Promise(() => {}))
      setStoredToken('fixture-new')
      expect(keeperWaitingInventoryState('cached')).toMatchObject({ inventory: null, ready: false, loading: true, error: null })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
    } finally { stop() }
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
    await Promise.resolve()
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    expect(intervalSpy).not.toHaveBeenCalled()

    mocks.pushRefresh?.('rondo')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
    mocks.pushRefresh?.('exampleorg')
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
})
