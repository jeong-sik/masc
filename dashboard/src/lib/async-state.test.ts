import { describe, it, expect } from 'vitest'
import {
  idle,
  loading,
  loaded,
  failed,
  isLoaded,
  isLoading,
  isFailed,
  getData,
  createAsyncResource,
  createManagedAsyncResource,
  type AsyncState,
} from './async-state'

describe('AsyncState constructors', () => {
  it('idle has status "idle"', () => {
    expect(idle.status).toBe('idle')
  })

  it('loading has status "loading"', () => {
    expect(loading.status).toBe('loading')
  })

  it('loaded wraps data', () => {
    const state = loaded({ count: 42 })
    expect(state.status).toBe('loaded')
    expect(state.data).toEqual({ count: 42 })
  })

  it('failed wraps error message', () => {
    const state = failed('network error')
    expect(state.status).toBe('error')
    expect(state.message).toBe('network error')
  })
})

describe('type guards', () => {
  it('isLoaded returns true only for loaded state', () => {
    expect(isLoaded(loaded(1))).toBe(true)
    expect(isLoaded(idle)).toBe(false)
    expect(isLoaded(loading)).toBe(false)
    expect(isLoaded(failed('err'))).toBe(false)
  })

  it('isLoading returns true only for loading state', () => {
    expect(isLoading(loading)).toBe(true)
    expect(isLoading(idle)).toBe(false)
  })

  it('isFailed returns true only for error state', () => {
    expect(isFailed(failed('err'))).toBe(true)
    expect(isFailed(loaded('ok'))).toBe(false)
  })
})

describe('getData', () => {
  it('extracts data from loaded state', () => {
    expect(getData(loaded(99))).toBe(99)
  })

  it('returns undefined for non-loaded states', () => {
    expect(getData(idle)).toBeUndefined()
    expect(getData(loading)).toBeUndefined()
    expect(getData(failed('err'))).toBeUndefined()
  })
})

describe('createAsyncResource', () => {
  it('starts in idle state', () => {
    const resource = createAsyncResource<string>()
    expect(resource.state.value.status).toBe('idle')
  })

  it('transitions through loading → loaded on success', async () => {
    const resource = createAsyncResource<number>()
    const states: AsyncState<number>[] = []

    // Capture state transitions
    const unsubscribe = resource.state.subscribe(s => states.push(s))

    await resource.load(async () => 42)
    unsubscribe()

    expect(states.map(s => s.status)).toEqual(['idle', 'loading', 'loaded'])
    const final = resource.state.value
    expect(final.status).toBe('loaded')
    if (final.status === 'loaded') {
      expect(final.data).toBe(42)
    }
  })

  it('transitions through loading → error on failure', async () => {
    const resource = createAsyncResource<number>()

    await resource.load(async () => {
      throw new Error('fetch failed')
    })

    const final = resource.state.value
    expect(final.status).toBe('error')
    if (final.status === 'error') {
      expect(final.message).toBe('fetch failed')
    }
  })

  it('deduplicates concurrent load calls', async () => {
    const resource = createAsyncResource<string>()
    let callCount = 0
    const fn = async () => {
      callCount++
      return 'result'
    }

    const p1 = resource.load(fn)
    const p2 = resource.load(fn)

    await Promise.all([p1, p2])
    expect(callCount).toBe(1)
  })

  it('allows new load after previous completes', async () => {
    const resource = createAsyncResource<number>()

    await resource.load(async () => 1)
    expect(getData(resource.state.value)).toBe(1)

    await resource.load(async () => 2)
    expect(getData(resource.state.value)).toBe(2)
  })

  it('reset returns to idle', async () => {
    const resource = createAsyncResource<string>()
    await resource.load(async () => 'data')
    expect(resource.state.value.status).toBe('loaded')

    resource.reset()
    expect(resource.state.value.status).toBe('idle')
  })

  it('handles non-Error throws', async () => {
    const resource = createAsyncResource<string>()

    await resource.load(async () => {
      throw 'string error'
    })

    const final = resource.state.value
    expect(final.status).toBe('error')
    if (final.status === 'error') {
      expect(final.message).toBe('string error')
    }
  })

  it('handles synchronous throws in load function', async () => {
    const resource = createAsyncResource<string>()

    await resource.load(() => {
      throw new Error('sync boom')
    })

    const final = resource.state.value
    expect(final.status).toBe('error')
    if (final.status === 'error') {
      expect(final.message).toBe('sync boom')
    }
  })

  it('allows reload after synchronous throw', async () => {
    const resource = createAsyncResource<string>()

    await resource.load(() => {
      throw new Error('sync fail')
    })
    expect(resource.state.value.status).toBe('error')

    await resource.load(async () => 'recovered')
    expect(getData(resource.state.value)).toBe('recovered')
  })

  it('reset while inflight discards the stale result', async () => {
    const resource = createAsyncResource<string>()
    let resolve: (v: string) => void
    const p = resource.load(() => new Promise<string>(r => { resolve = r }))

    expect(resource.state.value.status).toBe('loading')

    resource.reset()
    expect(resource.state.value.status).toBe('idle')

    resolve!('stale')
    await p

    expect(resource.state.value.status).toBe('idle')
  })

  it('allows new load after reset cancels inflight', async () => {
    const resource = createAsyncResource<string>()
    let resolve: (v: string) => void
    const p1 = resource.load(() => new Promise<string>(r => { resolve = r }))

    resource.reset()
    const p2 = resource.load(async () => 'fresh')
    await p2

    expect(getData(resource.state.value)).toBe('fresh')

    resolve!('stale')
    await p1

    expect(getData(resource.state.value)).toBe('fresh')
  })
})

describe('createManagedAsyncResource', () => {
  it('keeps previous data visible while refreshing', async () => {
    const resource = createManagedAsyncResource<number>(3)
    let resolve!: (value: number) => void

    const inflight = resource.load(() => new Promise<number>(r => { resolve = r }))

    expect(resource.state.value).toEqual({
      data: 3,
      loading: true,
      error: null,
    })

    resolve(9)
    await inflight

    expect(resource.state.value).toEqual({
      data: 9,
      loading: false,
      error: null,
    })
  })

  it('drops stale results from aborted requests', async () => {
    const resource = createManagedAsyncResource<string>('current')
    let resolveFirst!: (value: string) => void

    const first = resource.load((signal) => new Promise<string>((resolve, reject) => {
      resolveFirst = resolve
      signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
    }))

    const second = resource.load(async () => 'next')
    resolveFirst('stale')

    await Promise.all([first, second])

    expect(resource.state.value).toEqual({
      data: 'next',
      loading: false,
      error: null,
    })
  })

  it('preserves previous data on failure', async () => {
    const resource = createManagedAsyncResource<string>('stable')

    await resource.load(async () => {
      throw new Error('boom')
    })

    expect(resource.state.value).toEqual({
      data: 'stable',
      loading: false,
      error: 'boom',
    })
  })

  it('cancel stops the request without replacing current data', async () => {
    const resource = createManagedAsyncResource<string>('keep')

    void resource.load((signal) => new Promise<string>((resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
      setTimeout(() => resolve('late'), 10)
    }))

    resource.cancel()
    await Promise.resolve()

    expect(resource.state.value).toEqual({
      data: 'keep',
      loading: false,
      error: null,
    })
  })
})
