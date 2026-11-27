import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { effect } from '@preact/signals'
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

  it('catches loader exceptions cleanly into Observed failed without wedging in loading', async () => {
    const failed = await cache.fetch('exploding', async () => {
      throw new Error('unexpected json parse boom')
    })
    expect(failed.kind).toBe('failed')
    if (failed.kind === 'failed') {
      expect(failed.error.code).toBe('loader_threw')
      expect(failed.error.message).toContain('unexpected json parse boom')
      expect(failed.retryable).toBe(true)
    }

    // Subsequent fetch is NOT wedged by a stale inFlight promise
    const recovered = await cache.fetch('exploding', async () => ok({ ok: true }))
    expect(recovered.kind).toBe('value')
  })

  it('batches multi-topic invalidation and avoids redundant stale emissions on refresh', async () => {
    await Promise.all([
      cache.fetch('k1', async () => ok('v1'), { ttlMs: 30_000, topics: ['keeper', 'shell'] }),
      cache.fetch('k2', async () => ok('v2'), { ttlMs: 30_000, topics: ['keeper', 'keeper_turn'] }),
    ])
    const s1 = cache.observe<string>('k1')
    const s2 = cache.observe<string>('k2')

    let runs = 0
    const dispose = effect(() => {
      void s1.value
      void s2.value
      runs += 1
    })
    expect(runs).toBe(1)

    const count = cache.invalidateTopics(['keeper', 'shell', 'keeper_turn'])
    expect(count).toBe(2)
    expect(runs).toBe(2) // Single batched flush across both entries & overlapping topics

    // Starting a fetch for an already-stale value must NOT emit a duplicate stale render
    let resolveNext!: (v: ReturnType<typeof ok<string>>) => void
    const pending = cache.fetch<string>(
      'k1',
      () => new Promise<ReturnType<typeof ok<string>>>((r) => { resolveNext = r }),
      { ttlMs: 30_000, reason: 'sse' },
    )
    expect(runs).toBe(2)
    resolveNext(ok('v1-next'))
    await pending
    expect(runs).toBe(3)
    dispose()
  })
})
