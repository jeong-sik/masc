import { afterEach, describe, expect, it, vi } from 'vitest'
import type { KeeperWaitingInventoryChange } from './sse-store'

type ObserverCallbacks = {
  ready: (instance: string) => void
  change: (change: KeeperWaitingInventoryChange) => void
  unavailable: (reason: 'disconnected' | 'credentials_changed' | 'access_refused' | 'scope_changed') => void
}

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  observer: null as ObserverCallbacks | null,
  stop: vi.fn(),
  invalidate: vi.fn(),
}))

vi.mock('./api', () => ({ fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory }))
vi.mock('./keeper-waiting-observer-client', () => ({
  startKeeperWaitingObserver: (callbacks: ObserverCallbacks) => {
    mocks.observer = callbacks
    return { stop: mocks.stop, invalidate: () => { mocks.invalidate(); callbacks.unavailable('scope_changed') } }
  },
}))

import { keeperWaitingInventoryState, subscribeKeeperWaitingInventory } from './keeper-waiting-inventory-store'
import { ApiRequestError } from './api/core'

afterEach(() => {
  vi.restoreAllMocks()
  mocks.fetchKeeperWaitingInventory.mockReset()
  mocks.stop.mockReset()
  mocks.invalidate.mockReset()
  mocks.observer = null
})

describe('keeper waiting inventory store', () => {
  it('waits for an observer and follows keeper changes without installing a poll', async () => {
    let releaseFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementationOnce(() => new Promise(resolve => { releaseFirst = resolve }))
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: [] })
    const intervalSpy = vi.spyOn(window, 'setInterval')
    const stopLane = subscribeKeeperWaitingInventory('exampleorg')
    const stopConversation = subscribeKeeperWaitingInventory('exampleorg')
    try {
      expect(mocks.fetchKeeperWaitingInventory).not.toHaveBeenCalled()
      mocks.observer?.ready('process.epoch')
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledExactlyOnceWith('exampleorg', 'process.epoch')
      expect(intervalSpy).not.toHaveBeenCalled()
      mocks.observer?.change({ scope: 'keeper', keeperName: 'other' })
      mocks.observer?.change({ scope: 'keeper', keeperName: 'exampleorg' })
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)
      releaseFirst({ keepers: [] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
      await vi.waitFor(() => expect(keeperWaitingInventoryState('exampleorg').observerCurrent).toBe(true))

      const visibility = vi.spyOn(document, 'visibilityState', 'get')
      visibility.mockReturnValue('hidden')
      document.dispatchEvent(new Event('visibilitychange'))
      expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2)
      visibility.mockReturnValue('visible')
      document.dispatchEvent(new Event('visibilitychange'))
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3))
    } finally {
      stopConversation()
      stopLane()
    }
    expect(mocks.stop).toHaveBeenCalledOnce()
  })

  it('refreshes all subscribed keepers after a workspace change, including a trailing read', async () => {
    let releaseFirst!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory.mockImplementation((name: string) => {
      const count = mocks.fetchKeeperWaitingInventory.mock.calls.filter(([value]) => value === name).length
      if (name === 'alpha' && count === 1) return new Promise(resolve => { releaseFirst = resolve })
      return Promise.resolve({ keepers: [] })
    })
    const stopAlpha = subscribeKeeperWaitingInventory('alpha')
    const stopBeta = subscribeKeeperWaitingInventory('beta')
    try {
      mocks.observer?.ready('process.epoch')
      await vi.waitFor(() => expect(keeperWaitingInventoryState('beta').observerCurrent).toBe(true))
      mocks.observer?.change({ scope: 'workspace' })
      expect(keeperWaitingInventoryState('beta').observerCurrent).toBe(false)
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3))
      releaseFirst({ keepers: [] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(4))
      expect(mocks.fetchKeeperWaitingInventory.mock.calls.filter(([name]) => name === 'alpha')).toHaveLength(2)
      expect(mocks.fetchKeeperWaitingInventory.mock.calls.filter(([name]) => name === 'beta')).toHaveLength(2)
    } finally {
      stopAlpha()
      stopBeta()
    }
  })

  it('marks a crossing read stale until the replacement stream is revalidated', async () => {
    let releaseOld!: (value: { keepers: never[] }) => void
    let releaseNew!: (value: { keepers: never[] }) => void
    mocks.fetchKeeperWaitingInventory
      .mockImplementationOnce(() => new Promise(resolve => { releaseOld = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { releaseNew = resolve }))
    const stop = subscribeKeeperWaitingInventory('reconnected')
    try {
      mocks.observer?.ready('process.epoch')
      mocks.observer?.unavailable('disconnected')
      mocks.observer?.ready('process.epoch')
      releaseOld({ keepers: [] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
      expect(keeperWaitingInventoryState('reconnected').observerCurrent).toBe(false)
      releaseNew({ keepers: [] })
      await vi.waitFor(() => expect(keeperWaitingInventoryState('reconnected').observerCurrent).toBe(true))
      mocks.observer?.unavailable('disconnected')
      expect(keeperWaitingInventoryState('reconnected').observerCurrent).toBe(false)
    } finally {
      stop()
    }
  })

  it('withdraws an old workspace and ignores reads that cross into a new one', async () => {
    let releaseOld!: (value: { keepers: string[] }) => void
    let releaseNew!: (value: { keepers: string[] }) => void
    mocks.fetchKeeperWaitingInventory
      .mockResolvedValueOnce({ keepers: ['workspace-a'] })
      .mockImplementationOnce(() => new Promise(resolve => { releaseOld = resolve }))
      .mockImplementationOnce(() => new Promise(resolve => { releaseNew = resolve }))
    const stop = subscribeKeeperWaitingInventory('scope-change')
    try {
      mocks.observer?.ready('process.workspace-a')
      await vi.waitFor(() => expect(keeperWaitingInventoryState('scope-change').observerCurrent).toBe(true))
      mocks.observer?.change({ scope: 'keeper', keeperName: 'scope-change' })
      mocks.observer?.unavailable('disconnected')
      expect(keeperWaitingInventoryState('scope-change').inventory?.keepers).toEqual(['workspace-a'])
      mocks.observer?.ready('process.workspace-b')
      expect(keeperWaitingInventoryState('scope-change').inventory).toBeNull()
      releaseOld({ keepers: ['late-workspace-a'] })
      await vi.waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(3))
      expect(keeperWaitingInventoryState('scope-change').inventory).toBeNull()
      releaseNew({ keepers: ['workspace-b'] })
      await vi.waitFor(() => expect(keeperWaitingInventoryState('scope-change').inventory?.keepers).toEqual(['workspace-b']))
    } finally {
      stop()
    }
  })

  it.each(['credentials_changed', 'access_refused'] as const)('withdraws data on %s', async reason => {
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: ['private'] })
    const stop = subscribeKeeperWaitingInventory(`auth-${reason}`)
    try {
      mocks.observer?.ready('process.auth')
      await vi.waitFor(() => expect(keeperWaitingInventoryState(`auth-${reason}`).observerCurrent).toBe(true))
      mocks.observer?.unavailable(reason)
      expect(keeperWaitingInventoryState(`auth-${reason}`).inventory).toBeNull()
      expect(keeperWaitingInventoryState(`auth-${reason}`).ready).toBe(false)
    } finally {
      stop()
    }
  })

  it('withdraws the keeper snapshot if its inventory read is refused', async () => {
    mocks.fetchKeeperWaitingInventory
      .mockResolvedValueOnce({ keepers: ['private'] })
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/waiting-inventory', status: 403 }))
    const stop = subscribeKeeperWaitingInventory('read-refused')
    try {
      mocks.observer?.ready('process.auth')
      await vi.waitFor(() => expect(keeperWaitingInventoryState('read-refused').observerCurrent).toBe(true))
      mocks.observer?.change({ scope: 'keeper', keeperName: 'read-refused' })
      await vi.waitFor(() => expect(keeperWaitingInventoryState('read-refused').error).not.toBeNull())
      expect(keeperWaitingInventoryState('read-refused').inventory).toBeNull()
      expect(keeperWaitingInventoryState('read-refused').ready).toBe(false)
    } finally {
      stop()
    }
  })

  it('retires the stream and withdraws retained data on a generation conflict', async () => {
    mocks.fetchKeeperWaitingInventory
      .mockResolvedValueOnce({ keepers: ['workspace-a'] })
      .mockRejectedValueOnce(new ApiRequestError({
        method: 'GET', path: '/waiting-inventory', status: 409, errorCode: 'observer_instance_changed',
      }))
    const stop = subscribeKeeperWaitingInventory('scope-conflict')
    try {
      mocks.observer?.ready('process.workspace-a')
      await vi.waitFor(() => expect(keeperWaitingInventoryState('scope-conflict').observerCurrent).toBe(true))
      mocks.observer?.change({ scope: 'keeper', keeperName: 'scope-conflict' })
      await vi.waitFor(() => expect(mocks.invalidate).toHaveBeenCalledOnce())
      expect(keeperWaitingInventoryState('scope-conflict').inventory).toBeNull()
      expect(keeperWaitingInventoryState('scope-conflict').loading).toBe(false)
    } finally {
      stop()
    }
  })

  it('withdraws retained data when the last surface unsubscribes', async () => {
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({ keepers: ['private'] })
    const stop = subscribeKeeperWaitingInventory('closed-view')
    mocks.observer?.ready('process.auth')
    await vi.waitFor(() => expect(keeperWaitingInventoryState('closed-view').observerCurrent).toBe(true))
    stop()
    expect(keeperWaitingInventoryState('closed-view').inventory).toBeNull()
  })
})
