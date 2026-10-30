import { afterEach, describe, expect, it } from 'vitest'
import { globalShortcutManager } from './global-shortcut-manager'

afterEach(() => {
  globalShortcutManager.unregisterAll()
})

describe('globalShortcutManager — RFC-0012 dashboard root host', () => {
  it('exposes the headless-core KeyboardShortcutManager surface', () => {
    expect(typeof globalShortcutManager.register).toBe('function')
    expect(typeof globalShortcutManager.unregisterAll).toBe('function')
    expect(typeof globalShortcutManager.dispatch).toBe('function')
    expect(typeof globalShortcutManager.subscribe).toBe('function')
    expect(typeof globalShortcutManager.formatChord).toBe('function')
    expect(typeof globalShortcutManager.formatAria).toBe('function')
  })

  it('returns the same instance on repeated import (singleton)', async () => {
    const reimported = (await import('./global-shortcut-manager')).globalShortcutManager
    expect(reimported).toBe(globalShortcutManager)
  })

  it('register + dispatch fires the action and returns true on match', () => {
    let fired = 0
    globalShortcutManager.register({
      id: 'test.cmd-b',
      chord: { key: 'F1', modifiers: [] },
      description: 'test bind',
      scope: 'global',
      action: () => { fired += 1 },
    })

    const matched = globalShortcutManager.dispatch({
      key: 'F1',
      target: null,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    })

    expect(matched).toBe(true)
    expect(fired).toBe(1)
  })

  it('dispatch returns false (fall-through) when no shortcut matches', () => {
    // Registry is empty after afterEach unregisterAll. No registration here:
    // the host wire-in must NOT preventDefault when there is nothing to fire,
    // so existing ad-hoc keydown listeners keep working until their owners
    // migrate per RFC-0012 §8.
    const matched = globalShortcutManager.dispatch({
      key: 'F1',
      target: null,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    })
    expect(matched).toBe(false)
  })

  it('unregister return cleans up so the same id can re-register', () => {
    let firedV1 = 0
    let firedV2 = 0
    const dispose = globalShortcutManager.register({
      id: 'test.cmd-b',
      chord: { key: 'F1', modifiers: [] },
      description: 'v1',
      scope: 'global',
      action: () => { firedV1 += 1 },
    })
    dispose()

    globalShortcutManager.register({
      id: 'test.cmd-b',
      chord: { key: 'F1', modifiers: [] },
      description: 'v2',
      scope: 'global',
      action: () => { firedV2 += 1 },
    })

    globalShortcutManager.dispatch({
      key: 'F1',
      target: null,
      preventDefault: () => undefined,
      stopPropagation: () => undefined,
    })

    expect(firedV1).toBe(0)
    expect(firedV2).toBe(1)
  })

  it('subscribe receives the snapshot on each registry change', () => {
    const snapshots: number[] = []
    const unsub = globalShortcutManager.subscribe(s => snapshots.push(s.length))
    const dispose = globalShortcutManager.register({
      id: 'test.cmd-b',
      chord: { key: 'F1', modifiers: [] },
      description: '',
      scope: 'global',
      action: () => undefined,
    })
    dispose()
    unsub()

    expect(snapshots).toEqual([1, 0])
  })
})
