import { afterEach, describe, expect, it, vi } from 'vitest'
import type { KeeperWaitingInventoryChange } from './sse-store'

type Observer = {
  signal: AbortSignal
  ready: (instance: string) => void
  change: (change: KeeperWaitingInventoryChange) => void
  fail: (reason: Error) => void
}

const mocks = vi.hoisted(() => ({
  observers: [] as Observer[],
  tokenChanged: null as (() => void) | null,
}))

vi.mock('./api/keeper-waiting-observer', () => ({
  observeKeeperWaitingChanges: (signal: AbortSignal, ready: Observer['ready'], change: Observer['change']) =>
    new Promise<void>((_resolve, reject) => {
      mocks.observers.push({ signal, ready, change, fail: reject })
      signal.addEventListener('abort', () => reject(new DOMException('stopped', 'AbortError')), { once: true })
    }),
}))
vi.mock('./api/core', () => ({
  subscribeStoredTokenChanges: (callback: () => void) => {
    mocks.tokenChanged = callback
    return () => { mocks.tokenChanged = null }
  },
}))

import { startKeeperWaitingObserver } from './keeper-waiting-observer-client'
import { ObserverAccessError } from './lib/observer-protocol'

afterEach(() => {
  mocks.observers.length = 0
  mocks.tokenChanged = null
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('Keeper waiting observer lifecycle', () => {
  it('reconnects after failure but makes no timed reads while connected', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    const ready = vi.fn()
    const change = vi.fn()
    const unavailable = vi.fn()
    const stop = startKeeperWaitingObserver({ ready, change, unavailable })
    try {
      expect(mocks.observers).toHaveLength(1)
      mocks.observers[0]!.ready('process.first')
      await vi.advanceTimersByTimeAsync(120_000)
      expect(mocks.observers).toHaveLength(1)
      mocks.observers[0]!.fail(new Error('connection lost'))
      await vi.advanceTimersByTimeAsync(999)
      expect(unavailable).toHaveBeenCalledOnce()
      expect(mocks.observers).toHaveLength(1)
      await vi.advanceTimersByTimeAsync(1)
      expect(mocks.observers).toHaveLength(2)
      mocks.observers[0]!.change({ scope: 'workspace' })
      mocks.observers[1]!.ready('process.second')
      mocks.observers[1]!.change({ scope: 'keeper', keeperName: 'alpha' })
      expect(ready.mock.calls).toEqual([['process.first'], ['process.second']])
      expect(change.mock.calls).toEqual([[{ scope: 'keeper', keeperName: 'alpha' }]])
    } finally {
      stop.stop()
    }
  })

  it('retires the old stream when credentials change and cancels work on unsubscribe', async () => {
    vi.useFakeTimers()
    const callbacks = { ready: vi.fn(), change: vi.fn(), unavailable: vi.fn() }
    const stop = startKeeperWaitingObserver(callbacks)
    mocks.observers[0]!.ready('process.first')
    mocks.tokenChanged?.()
    expect(mocks.observers[0]!.signal.aborted).toBe(true)
    expect(callbacks.unavailable).toHaveBeenCalledOnce()
    expect(callbacks.unavailable).toHaveBeenCalledWith('credentials_changed')
    expect(mocks.observers).toHaveLength(2)
    mocks.observers[0]!.ready('old')
    expect(callbacks.ready).toHaveBeenCalledOnce()
    stop.stop()
    expect(mocks.observers[1]!.signal.aborted).toBe(true)
    await vi.runAllTimersAsync()
    expect(mocks.observers).toHaveLength(2)
    expect(mocks.tokenChanged).toBeNull()
  })

  it('distinguishes access refusal from a disconnected stream', async () => {
    vi.useFakeTimers()
    const callbacks = { ready: vi.fn(), change: vi.fn(), unavailable: vi.fn() }
    const stop = startKeeperWaitingObserver(callbacks)
    try {
      mocks.observers[0]!.fail(new ObserverAccessError(403))
      await vi.advanceTimersByTimeAsync(0)
      expect(callbacks.unavailable).toHaveBeenCalledWith('access_refused')
    } finally {
      stop.stop()
    }
  })

  it('retires a mismatched observer and retries with backoff', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    const callbacks = { ready: vi.fn(), change: vi.fn(), unavailable: vi.fn() }
    const control = startKeeperWaitingObserver(callbacks)
    try {
      mocks.observers[0]!.ready('process.first')
      control.invalidate()
      expect(callbacks.unavailable).toHaveBeenCalledWith('scope_changed')
      expect(mocks.observers[0]!.signal.aborted).toBe(true)
      await vi.advanceTimersByTimeAsync(999)
      expect(mocks.observers).toHaveLength(1)
      await vi.advanceTimersByTimeAsync(1)
      expect(mocks.observers).toHaveLength(2)
    } finally {
      control.stop()
    }
  })
})
