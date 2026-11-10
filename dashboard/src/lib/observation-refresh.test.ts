import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  publishDashboardObservationChange,
  publishDashboardObservationRecovery,
  setupObservationRefresh,
} from './observation-refresh'

const disposers: Array<() => void> = []
const flush = async () => { await Promise.resolve(); await Promise.resolve() }

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('authoritative observation reads', () => {
  it('reads initially and after a matching change, without periodic HTTP', async () => {
    vi.useFakeTimers()
    const read = vi.fn(async () => ({ state: 'ready' }))
    disposers.push(setupObservationRefresh(read, { topics: ['health'] }))
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(180_000)
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'logs' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'health' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('preserves one trailing authoritative read for a burst during a slow read', async () => {
    let finish!: () => void
    let current = 'before'
    let observed = ''
    const read = vi.fn(async () => {
      const value = current
      if (read.mock.calls.length === 1) await new Promise<void>(resolve => { finish = resolve })
      observed = value
    })
    disposers.push(setupObservationRefresh(read, { topics: ['verification_requests'] }))
    await flush()
    current = 'after'
    publishDashboardObservationChange({ topic: 'verification_requests' })
    publishDashboardObservationChange({ topic: 'verification_requests' })
    expect(read).toHaveBeenCalledTimes(1)
    finish()
    await flush()
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(observed).toBe('after')
  })

  it('limits a scoped chat observation to its original operation', async () => {
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, {
      topics: ['chat_operation'], keeperName: 'alpha', operationId: 'original',
    }))
    await flush()
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'beta', operationId: 'original' })
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'other' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'original' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('remembers hidden invalidation and coalesces visibility with focus', async () => {
    let visibility: DocumentVisibilityState = 'hidden'
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility)
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, { topics: ['tools'] }))
    publishDashboardObservationChange({ topic: 'tools' })
    await flush()
    expect(read).not.toHaveBeenCalled()
    visibility = 'visible'
    document.dispatchEvent(new Event('visibilitychange'))
    window.dispatchEvent(new Event('focus'))
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
  })

  it('retires a crossing read on recovery and reads again after it settles', async () => {
    let finish!: () => void
    const signals: AbortSignal[] = []
    const read = vi.fn(async (signal: AbortSignal) => {
      signals.push(signal)
      if (signals.length === 1) await new Promise<void>(resolve => { finish = resolve })
    })
    disposers.push(setupObservationRefresh(read, { topics: ['runtime_probe'] }))
    await flush()
    publishDashboardObservationRecovery()
    expect(signals[0]!.aborted).toBe(true)
    finish()
    await flush()
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(signals[1]!.aborted).toBe(false)
  })

  it('stops trailing reads and listeners when the surface unmounts', async () => {
    let finish!: () => void
    const read = vi.fn(() => new Promise<void>(resolve => { finish = resolve }))
    const dispose = setupObservationRefresh(read, { topics: ['logs'] })
    await flush()
    publishDashboardObservationChange({ topic: 'logs' })
    dispose()
    finish()
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
  })
})
