// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { persistentSignal, readPersistedValue } from './persistent-signal'

describe('readPersistedValue (pure)', () => {
  it('returns default when raw is null (missing key)', () => {
    expect(readPersistedValue(null, false)).toBe(false)
    expect(readPersistedValue(null, 42)).toBe(42)
    expect(readPersistedValue(null, 'default')).toBe('default')
  })

  it('parses valid JSON and returns it', () => {
    expect(readPersistedValue('true', false)).toBe(true)
    expect(readPersistedValue('42', 0)).toBe(42)
    expect(readPersistedValue('"hi"', 'default')).toBe('hi')
  })

  it('returns default on invalid JSON (no throw — corruption recovery)', () => {
    // Regression guard: a bad entry must not brick the UI. Next write
    // will overwrite, so silent fallback is the right move.
    expect(readPersistedValue('not valid json', 'fallback')).toBe('fallback')
    expect(readPersistedValue('{oops', { a: 1 })).toEqual({ a: 1 })
  })

  it('respects custom deserialize', () => {
    const deserialize = (raw: string): number => parseInt(raw, 10) * 2
    expect(readPersistedValue('5', 0, deserialize)).toBe(10)
  })
})

describe('persistentSignal (component)', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  it('returns default value when the key is absent', () => {
    const sig = persistentSignal({ key: 'test:absent', defaultValue: false })
    expect(sig.value).toBe(false)
  })

  it('hydrates from localStorage when the key is present', () => {
    window.localStorage.setItem('test:present', 'true')
    const sig = persistentSignal({ key: 'test:present', defaultValue: false })
    expect(sig.value).toBe(true)
  })

  it('writes to localStorage on value change', () => {
    const sig = persistentSignal({ key: 'test:write', defaultValue: false })
    sig.value = true
    expect(window.localStorage.getItem('test:write')).toBe('true')
  })

  it('does NOT write on initial load (avoids churn when nothing changed)', () => {
    // Regression guard: creating a signal with defaultValue should not
    // immediately populate localStorage — only real changes do. This
    // keeps boot-time writes down and matches the \"only persist what
    // the user actually chose\" intuition.
    const sig = persistentSignal({ key: 'test:no-initial-write', defaultValue: false })
    expect(window.localStorage.getItem('test:no-initial-write')).toBeNull()
    // Reading the value doesn't trigger a write either.
    expect(sig.value).toBe(false)
    expect(window.localStorage.getItem('test:no-initial-write')).toBeNull()
  })

  it('handles objects (serialized via JSON)', () => {
    const sig = persistentSignal({
      key: 'test:obj',
      defaultValue: { a: 1, b: 'x' } as { a: number; b: string },
    })
    sig.value = { a: 2, b: 'y' }
    expect(JSON.parse(window.localStorage.getItem('test:obj') ?? '{}')).toEqual({ a: 2, b: 'y' })
  })

  it('falls back to default when stored value is corrupt', () => {
    window.localStorage.setItem('test:corrupt', '{this is not valid json')
    const sig = persistentSignal({ key: 'test:corrupt', defaultValue: 'fallback' })
    expect(sig.value).toBe('fallback')
  })

  it('never throws when localStorage.setItem throws (quota / privacy)', () => {
    // Simulate a quota-exceeded environment — privacy-locked Safari
    // sometimes throws on set. The signal must keep working for reads.
    const setItemSpy = vi.spyOn(window.localStorage, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })
    try {
      const sig = persistentSignal({ key: 'test:quota', defaultValue: false })
      // The change itself must not throw even though set will fail.
      expect(() => { sig.value = true }).not.toThrow()
      expect(sig.value).toBe(true)
    } finally {
      setItemSpy.mockRestore()
    }
  })
})
