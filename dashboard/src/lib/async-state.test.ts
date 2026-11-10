import { describe, it, expect } from 'vitest'
import {
  idle, loading, loaded, failed,
  isLoaded, isLoading, isFailed,
  getData, isAbortError, createManagedAsyncResource,
} from './async-state'

describe('async-state constructors', () => {
  it('idle has status idle', () => { expect(idle).toEqual({ status: 'idle' }) })
  it('loading has status loading', () => { expect(loading).toEqual({ status: 'loading' }) })
  it('loaded wraps data', () => { expect(loaded(42)).toEqual({ status: 'loaded', data: 42 }) })
  it('loaded wraps object', () => { expect(loaded({ name: 'test' })).toEqual({ status: 'loaded', data: { name: 'test' } }) })
  it('failed wraps message', () => { expect(failed('oops')).toEqual({ status: 'error', message: 'oops' }) })
})

describe('isLoaded', () => {
  it('returns true for loaded', () => { expect(isLoaded(loaded('data'))).toBe(true) })
  it('returns false for idle', () => { expect(isLoaded(idle)).toBe(false) })
  it('returns false for loading', () => { expect(isLoaded(loading)).toBe(false) })
  it('returns false for failed', () => { expect(isFailed(failed('err'))).toBe(true) })
})

describe('isLoading', () => {
  it('returns true for loading', () => { expect(isLoading(loading)).toBe(true) })
  it('returns false for loaded', () => { expect(isLoading(loaded(1))).toBe(false) })
})

describe('isFailed', () => {
  it('returns true for failed', () => { expect(isFailed(failed('err'))).toBe(true) })
  it('returns false for idle', () => { expect(isFailed(idle)).toBe(false) })
  it('returns false for loaded', () => { expect(isFailed(loaded(1))).toBe(false) })
})

describe('getData', () => {
  it('extracts data from loaded', () => { expect(getData(loaded('hello'))).toBe('hello') })
  it('returns undefined for idle', () => { expect(getData(idle)).toBeUndefined() })
  it('returns undefined for loading', () => { expect(getData(loading)).toBeUndefined() })
  it('returns undefined for failed', () => { expect(getData(failed('err'))).toBeUndefined() })
  it('preserves falsy values', () => {
    expect(getData(loaded(0))).toBe(0)
    expect(getData(loaded(''))).toBe('')
    expect(getData(loaded(null))).toBeNull()
  })
})

describe('isAbortError', () => {
  it('detects AbortError', () => { expect(isAbortError(new DOMException('Aborted', 'AbortError'))).toBe(true) })
  it('returns false for regular Error', () => { expect(isAbortError(new Error('x'))).toBe(false) })
  it('returns false for non-Error', () => { expect(isAbortError('str')).toBe(false) })
  it('returns false for null', () => { expect(isAbortError(null)).toBe(false) })
})

describe('managed read failure', () => {
  it('keeps the original typed failure separately from its display message', async () => {
    const resource = createManagedAsyncResource<string>()
    const failure = Object.assign(new Error('denied'), { status: 403 })
    await resource.load(async () => { throw failure })
    expect(resource.state.peek().error).toBe('denied')
    expect(resource.readError()).toBe(failure)
    resource.reset()
    expect(resource.readError()).toBeNull()
    await resource.load(async () => 'new owner')
    expect(resource.readError()).toBeNull()
  })

  it('does not publish a late non-AbortError from a retired read', async () => {
    const resource = createManagedAsyncResource<string>()
    let reject!: (error: Error) => void
    const pending = resource.load(() => new Promise<string>((_resolve, fail) => { reject = fail }))
    resource.reset()
    await resource.load(async () => 'current')
    reject(new Error('late refusal'))
    await pending
    expect(resource.state.peek()).toEqual({ data: 'current', loading: false, error: null })
    expect(resource.readError()).toBeNull()
  })
})
