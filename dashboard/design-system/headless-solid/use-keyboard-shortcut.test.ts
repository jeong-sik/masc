// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot } from 'solid-js'
import { createKeyboardShortcutManager } from '../headless-core/keyboard-shortcuts'
import { useKeyboardShortcut, useKeyboardShortcutHost } from './use-keyboard-shortcut'

let dispose: (() => void) | undefined

beforeEach(() => {
  dispose = undefined
})

afterEach(() => {
  dispose?.()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

describe('useKeyboardShortcut', () => {
  it('registers a chord and returns display + aria strings', () => {
    const manager = createKeyboardShortcutManager()
    let triggered = 0
    const result = withRoot(() =>
      useKeyboardShortcut(
        manager,
        {
          chord: { key: 'k', modifiers: [] },
          action: () => { triggered += 1 },
          description: 'Open command palette',
          scope: 'global',
        },
        'cmd-palette',
      ),
    )
    expect(typeof result.display).toBe('string')
    expect(typeof result.aria).toBe('string')
    expect(result.display.length).toBeGreaterThan(0)
    expect(result.aria.length).toBeGreaterThan(0)
    // Verify registration is live: dispatch a matching event.
    const matched = manager.dispatch({
      key: 'k',
      metaKey: false,
      ctrlKey: false,
      shiftKey: false,
      altKey: false,
      target: null,
      preventDefault: () => {},
      stopPropagation: () => {},
    })
    expect(matched).toBe(true)
    expect(triggered).toBe(1)
  })

  it('createRoot dispose unregisters the chord', () => {
    const manager = createKeyboardShortcutManager()
    let triggered = 0
    const localDispose = createRoot((d) => {
      useKeyboardShortcut(
        manager,
        {
          chord: { key: 'a', modifiers: [] },
          action: () => { triggered += 1 },
          description: 'A',
          scope: 'global',
        },
        'a-shortcut',
      )
      return d
    })
    manager.dispatch({
      key: 'a', metaKey: false, ctrlKey: false, shiftKey: false, altKey: false,
      target: null, preventDefault: () => {}, stopPropagation: () => {},
    })
    expect(triggered).toBe(1)
    localDispose()
    manager.dispatch({
      key: 'a', metaKey: false, ctrlKey: false, shiftKey: false, altKey: false,
      target: null, preventDefault: () => {}, stopPropagation: () => {},
    })
    expect(triggered).toBe(1)
  })
})

describe('useKeyboardShortcutHost', () => {
  it('binds document keydown and fires registered shortcuts', () => {
    const manager = createKeyboardShortcutManager()
    let triggered = 0
    const localDispose = createRoot((d) => {
      useKeyboardShortcut(
        manager,
        {
          chord: { key: 'b', modifiers: [] },
          action: () => { triggered += 1 },
          description: 'B',
          scope: 'global',
        },
        'b-shortcut',
      )
      useKeyboardShortcutHost(manager)
      return d
    })
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'b' }))
    expect(triggered).toBe(1)
    localDispose()
  })

  it('unbinds the listener on dispose', () => {
    const manager = createKeyboardShortcutManager()
    let triggered = 0
    const localDispose = createRoot((d) => {
      useKeyboardShortcut(
        manager,
        {
          chord: { key: 'c', modifiers: [] },
          action: () => { triggered += 1 },
          description: 'C',
          scope: 'global',
        },
        'c-shortcut',
      )
      useKeyboardShortcutHost(manager)
      return d
    })
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'c' }))
    expect(triggered).toBe(1)
    localDispose()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'c' }))
    expect(triggered).toBe(1)
  })

  it('unmatched key falls through without throw', () => {
    const manager = createKeyboardShortcutManager()
    withRoot(() => useKeyboardShortcutHost(manager))
    expect(() => {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'q' }))
    }).not.toThrow()
  })
})
