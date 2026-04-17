import { html } from 'htm/preact'
import { cleanup, render, act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useSavedSignal } from './saved-signal'

// Small test harness: a component that calls the hook and exposes the
// current signal + reset via refs so the test can drive it.
interface HookRef<T> {
  getValue: () => T
  setValue: (v: T) => void
  reset: () => void
}

function makeHarness<T>(key: string, initial: T, ref: HookRef<T> | { current: HookRef<T> | null }) {
  const Host = () => {
    const [signal, reset] = useSavedSignal<T>(key, initial)
    const slot: HookRef<T> = {
      getValue: () => signal.value,
      setValue: (v) => { signal.value = v },
      reset,
    }
    if ('current' in ref) ref.current = slot
    else Object.assign(ref, slot)
    return html`<div data-testid="host">${String(signal.value)}</div>`
  }
  return Host
}

describe('useSavedSignal', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })
  afterEach(() => {
    cleanup()
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it('starts with initial when localStorage has no entry', () => {
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:none', 'init', ref)
    render(html`<${Host} />`)
    expect(ref.current?.getValue()).toBe('init')
  })

  it('hydrates from localStorage on mount when entry exists', () => {
    window.localStorage.setItem('dash:test:hydrate', JSON.stringify('stored-value'))
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:hydrate', 'init', ref)
    render(html`<${Host} />`)
    expect(ref.current?.getValue()).toBe('stored-value')
  })

  it('writes JSON on change', async () => {
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:write', '', ref)
    render(html`<${Host} />`)
    await act(async () => { ref.current?.setValue('hello') })
    expect(window.localStorage.getItem('dash:test:write')).toBe(JSON.stringify('hello'))
  })

  it('removes key when value is empty string (tidy)', async () => {
    window.localStorage.setItem('dash:test:tidy', JSON.stringify('prior'))
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:tidy', '', ref)
    render(html`<${Host} />`)
    // Initial value hydrated from storage = 'prior'; set back to ''
    await act(async () => { ref.current?.setValue('') })
    expect(window.localStorage.getItem('dash:test:tidy')).toBeNull()
  })

  it('removes key when value equals initial (tidy)', async () => {
    window.localStorage.setItem('dash:test:tidy-init', JSON.stringify('other'))
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:tidy-init', 'default', ref)
    render(html`<${Host} />`)
    await act(async () => { ref.current?.setValue('default') })
    expect(window.localStorage.getItem('dash:test:tidy-init')).toBeNull()
  })

  it('reset() clears localStorage and resets the signal', async () => {
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:reset', 'init', ref)
    render(html`<${Host} />`)
    await act(async () => { ref.current?.setValue('changed') })
    expect(window.localStorage.getItem('dash:test:reset')).toBe(JSON.stringify('changed'))
    await act(async () => { ref.current?.reset() })
    expect(ref.current?.getValue()).toBe('init')
    expect(window.localStorage.getItem('dash:test:reset')).toBeNull()
  })

  it('falls back to initial on malformed stored JSON and does not throw', () => {
    window.localStorage.setItem('dash:test:malformed', '{not valid json')
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const ref: { current: HookRef<string> | null } = { current: null }
    const Host = makeHarness('dash:test:malformed', 'init', ref)
    expect(() => render(html`<${Host} />`)).not.toThrow()
    expect(ref.current?.getValue()).toBe('init')
    expect(warn).toHaveBeenCalled()
  })

  it('round-trips numbers, booleans, and plain objects', async () => {
    const numRef: { current: HookRef<number> | null } = { current: null }
    render(html`<${makeHarness<number>('dash:test:num', 0, numRef)} />`)
    await act(async () => { numRef.current?.setValue(42) })
    expect(window.localStorage.getItem('dash:test:num')).toBe('42')

    const boolRef: { current: HookRef<boolean> | null } = { current: null }
    render(html`<${makeHarness<boolean>('dash:test:bool', false, boolRef)} />`)
    await act(async () => { boolRef.current?.setValue(true) })
    expect(window.localStorage.getItem('dash:test:bool')).toBe('true')

    type Obj = { a: number; b: string }
    const objRef: { current: HookRef<Obj> | null } = { current: null }
    render(html`<${makeHarness<Obj>('dash:test:obj', { a: 0, b: '' }, objRef)} />`)
    await act(async () => { objRef.current?.setValue({ a: 1, b: 'x' }) })
    expect(window.localStorage.getItem('dash:test:obj')).toBe(JSON.stringify({ a: 1, b: 'x' }))

    // Re-mount the object harness and confirm hydration.
    cleanup()
    const objRef2: { current: HookRef<Obj> | null } = { current: null }
    render(html`<${makeHarness<Obj>('dash:test:obj', { a: 0, b: '' }, objRef2)} />`)
    expect(objRef2.current?.getValue()).toEqual({ a: 1, b: 'x' })
  })

  it('survives absence of window.localStorage (SSR-ish)', () => {
    // Simulate localStorage being unavailable. We can't undefine `window` under
    // happy-dom cleanly, but we can replace localStorage with undefined.
    const original = Object.getOwnPropertyDescriptor(window, 'localStorage')
    try {
      Object.defineProperty(window, 'localStorage', { configurable: true, value: undefined })
      const ref: { current: HookRef<string> | null } = { current: null }
      const Host = makeHarness('dash:test:ssr', 'init', ref)
      expect(() => render(html`<${Host} />`)).not.toThrow()
      expect(ref.current?.getValue()).toBe('init')
    } finally {
      if (original) Object.defineProperty(window, 'localStorage', original)
    }
  })
})
