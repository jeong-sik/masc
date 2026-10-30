import { describe, it, expect } from 'vitest'
import {
  idle, loading, loaded, failed,
  isLoaded, isLoading, isFailed,
  getData, isAbortError,
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
