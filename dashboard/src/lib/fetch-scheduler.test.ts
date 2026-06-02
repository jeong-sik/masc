import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { FetchScheduler } from './fetch-scheduler'

describe('FetchScheduler', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('debounces rapid requests into a single fetch', async () => {
    const fetchFn = vi.fn().mockResolvedValue(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 300 })

    scheduler.request()
    scheduler.request()
    scheduler.request()

    expect(fetchFn).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(300)
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('enforces cooldown between fetches', async () => {
    const fetchFn = vi.fn().mockResolvedValue(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 100 })

    scheduler.requestNow()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetchFn).toHaveBeenCalledTimes(1)

    // Request right after — should be delayed by cooldown, not debounce
    scheduler.request()
    await vi.advanceTimersByTimeAsync(100)
    expect(fetchFn).toHaveBeenCalledTimes(1) // debounce expired but cooldown blocks

    await vi.advanceTimersByTimeAsync(1900)
    expect(fetchFn).toHaveBeenCalledTimes(2) // cooldown expired
  })

  it('requestNow() fires immediately without debounce', async () => {
    const fetchFn = vi.fn().mockResolvedValue(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 300 })

    scheduler.requestNow()
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('deduplicates during inflight — urgent pending triggers immediate re-fetch', async () => {
    let resolveFn!: () => void
    const fetchFn = vi.fn().mockImplementation(
      () => new Promise<void>(r => { resolveFn = r }),
    )
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 100 })

    scheduler.requestNow()
    expect(fetchFn).toHaveBeenCalledTimes(1)

    // Multiple requests absorbed during inflight
    scheduler.request()
    scheduler.request()
    scheduler.requestNow() // upgrades to urgent
    expect(fetchFn).toHaveBeenCalledTimes(1)

    // Complete the inflight fetch
    resolveFn()
    await vi.advanceTimersByTimeAsync(0)

    // Urgent pending → immediate re-fetch (no debounce/cooldown)
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })

  it('deduplicates during inflight — normal pending schedules cooldown-gated fetch', async () => {
    let resolveFn!: () => void
    const fetchFn = vi.fn().mockImplementation(
      () => new Promise<void>(r => { resolveFn = r }),
    )
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 500, debounceMs: 100 })

    scheduler.requestNow()
    scheduler.request() // normal priority during inflight

    resolveFn()
    await vi.advanceTimersByTimeAsync(0)

    expect(fetchFn).toHaveBeenCalledTimes(1) // not yet — cooldown

    await vi.advanceTimersByTimeAsync(500)
    expect(fetchFn).toHaveBeenCalledTimes(2) // cooldown expired
  })

  it('no re-fetch when nothing is pending after inflight completes', async () => {
    let resolveFn!: () => void
    const fetchFn = vi.fn().mockImplementation(
      () => new Promise<void>(r => { resolveFn = r }),
    )
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 500, debounceMs: 100 })

    scheduler.requestNow()
    resolveFn()
    await vi.advanceTimersByTimeAsync(0)

    expect(fetchFn).toHaveBeenCalledTimes(1)

    // Wait well past cooldown — no extra fetch
    await vi.advanceTimersByTimeAsync(5000)
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('dispose cancels pending timers', async () => {
    const fetchFn = vi.fn().mockResolvedValue(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 300 })

    scheduler.request()
    scheduler.dispose()

    await vi.advanceTimersByTimeAsync(5000)
    expect(fetchFn).not.toHaveBeenCalled()
  })

  it('recovers after fetch error — scheduler keeps working', async () => {
    const fetchFn = vi.fn()
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 100, debounceMs: 50 })

    scheduler.requestNow()
    await vi.advanceTimersByTimeAsync(0)

    // Scheduler still functional after error
    await vi.advanceTimersByTimeAsync(100)
    scheduler.requestNow()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })

  it('fetching getter reflects inflight state', async () => {
    let resolveFn!: () => void
    const fetchFn = vi.fn().mockImplementation(
      () => new Promise<void>(r => { resolveFn = r }),
    )
    const scheduler = new FetchScheduler(fetchFn)

    expect(scheduler.fetching).toBe(false)

    scheduler.requestNow()
    expect(scheduler.fetching).toBe(true)

    resolveFn()
    await vi.advanceTimersByTimeAsync(0)
    expect(scheduler.fetching).toBe(false)
  })

  it('inflightPromise is accessible for await-based callers', async () => {
    let resolveFn!: () => void
    const fetchFn = vi.fn().mockImplementation(
      () => new Promise<void>(r => { resolveFn = r }),
    )
    const scheduler = new FetchScheduler(fetchFn)

    expect(scheduler.inflightPromise).toBeNull()

    scheduler.requestNow()
    expect(scheduler.inflightPromise).not.toBeNull()

    resolveFn()
    await scheduler.inflightPromise
    // After microtask drain, should be null
    await vi.advanceTimersByTimeAsync(0)
    expect(scheduler.inflightPromise).toBeNull()
  })

  it('does not double-schedule when request() is called multiple times before timer fires', async () => {
    const fetchFn = vi.fn().mockResolvedValue(undefined)
    const scheduler = new FetchScheduler(fetchFn, { cooldownMs: 2000, debounceMs: 300 })

    scheduler.request()
    scheduler.request()
    scheduler.request()

    await vi.advanceTimersByTimeAsync(300)
    expect(fetchFn).toHaveBeenCalledTimes(1)

    // No extra fetches
    await vi.advanceTimersByTimeAsync(5000)
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })
})
