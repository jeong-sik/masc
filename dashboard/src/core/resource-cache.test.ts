import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { err, ok } from '../lib/result'
import { bumpSessionEpoch, resetAuthStateForTests } from './auth'
import {
  ResourceCache,
  formatObserved,
  observedAbsent,
  observedFailed,
  observedLoading,
  observedUnreported,
  observedValue,
} from './resource-cache'

describe('core/resource-cache & Observed<T>', () => {
  let nowMs = 1_000_000
  let cache: ResourceCache

  beforeEach(() => {
    resetAuthStateForTests()
    nowMs = 1_000_000
    cache = new ResourceCache(() => nowMs)
  })

  afterEach(() => {
    cache.dispose()
    resetAuthStateForTests()
  })

  it('formats Observed<T> honestly without conflating absent/unreported with zero', () => {
    expect(formatObserved(observedValue(0))).toBe('0')
    expect(formatObserved(observedValue(42), (n) => `${n}ms`)).toBe('42ms')
    expect(formatObserved(observedAbsent())).toBe('없음')
    expect(formatObserved(observedUnreported())).toBe('미보고')
    expect(formatObserved(observedLoading())).toBe('불러오는 중…')
    expect(
      formatObserved(
        observedFailed({
          kind: 'server',
          status: 500,
          code: null,
          message: 'boom',
          retryable: true,
        }),
      ),
    ).toBe('오류')
  })

  it('deduplicates concurrent GETs and blocks refetch storms on route/sse while fresh', async () => {
    let calls = 0
    const loader = vi.fn(async () => {
      calls += 1
      return ok({ total: calls })
    })

    const [a, b, c] = await Promise.all([
      cache.fetch('keepers', loader, { ttlMs: 10_000, topics: ['keeper_updated'], reason: 'mount' }),
      cache.fetch('keepers', loader, { ttlMs: 10_000, topics: ['keeper_updated'], reason: 'route' }),
      cache.fetch('keepers', loader, { ttlMs: 10_000, topics: ['keeper_updated'], reason: 'sse' }),
    ])

    expect(calls).toBe(1)
    expect(a.kind).toBe('value')
    expect(b).toEqual(a)
    expect(c).toEqual(a)

    // Subsequent route/sse reads within TTL MUST NOT refetch
    nowMs += 2_000
    await cache.fetch('keepers', loader, { ttlMs: 10_000, reason: 'route' })
    await cache.fetch('keepers', loader, { ttlMs: 10_000, reason: 'sse' })
    expect(calls).toBe(1)

    // Manual refresh explicitly bypasses fresh TTL
    const manual = await cache.fetch('keepers', loader, { ttlMs: 10_000, reason: 'manual' })
    expect(calls).toBe(2)
    expect(manual.kind === 'value' && manual.data.total).toBe(2)
  })

  it('marks topic subscribers stale lazily on invalidateTopic and clears all entries on sessionEpoch bump', async () => {
    let calls = 0
    const loader = vi.fn(async () => {
      calls += 1
      return ok({ v: calls })
    })

    await cache.fetch('board:list', loader, { ttlMs: 30_000, topics: ['board_changed'] })
    const obsSignal = cache.observe<{ v: number }>('board:list')
    expect(obsSignal.value.kind === 'value' && obsSignal.value.stale).toBe(false)

    // Topic invalidation marks stale without firing a fetch immediately
    const invalidated = cache.invalidateTopic('board_changed')
    expect(invalidated).toBe(1)
    expect(calls).toBe(1)
    expect(obsSignal.value.kind === 'value' && obsSignal.value.stale).toBe(true)

    // Next read refreshes cleanly
    await cache.fetch('board:list', loader, { ttlMs: 30_000, reason: 'route' })
    expect(calls).toBe(2)
    expect(obsSignal.value.kind === 'value' && obsSignal.value.stale).toBe(false)

    // Epoch bump clears cache back to loading
    bumpSessionEpoch()
    expect(obsSignal.value.kind).toBe('loading')
  })

  it('maps null payload and 404 not_found to Observed absent', async () => {
    const nullRes = await cache.fetch('empty', async () => ok(null))
    expect(nullRes.kind).toBe('absent')

    const nfRes = await cache.fetch('missing', async () =>
      err({ kind: 'not_found', status: 404, code: 'not_found', message: 'gone', retryable: false }),
    )
    expect(nfRes.kind).toBe('absent')
  })
})
