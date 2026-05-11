import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { createKeyboardShortcutManager } from '../../../design-system/headless-core/keyboard-shortcuts'
import { useKeeperPinShortcuts } from './use-keeper-pin-shortcuts'
import {
  clearPins,
  pinKeeper,
  pinnedKeepers,
} from './multi-keeper-pin-store'

const containers: HTMLElement[] = []

async function mountHost(
  manager: ReturnType<typeof createKeyboardShortcutManager>,
): Promise<HTMLElement> {
  function Host() {
    useKeeperPinShortcuts(manager)
    return html`<div data-testid="host" />`
  }
  const container = document.createElement('div')
  containers.push(container)
  render(html`<${Host} />`, container)
  // Preact schedules useEffect on a microtask but vitest+jsdom shows a
  // race on the first render of the file (registry empty after a single
  // setTimeout(0) tick). vi.waitFor polls until the side effect lands —
  // stable across cold/warm module state.
  await vi.waitFor(() => {
    if (manager.getAll().length < 5) throw new Error('shortcuts not registered yet')
  })
  return container
}

async function unmount(
  container: HTMLElement,
  manager: ReturnType<typeof createKeyboardShortcutManager>,
): Promise<void> {
  render(null, container)
  await vi.waitFor(() => {
    if (manager.getAll().length > 0) throw new Error('shortcuts not disposed yet')
  })
}

function fireChord(
  manager: ReturnType<typeof createKeyboardShortcutManager>,
  chordKey: string,
  modifiers: { meta?: boolean; shift?: boolean; ctrl?: boolean } = {},
): boolean {
  return manager.dispatch({
    key: chordKey,
    metaKey: modifiers.meta ?? false,
    ctrlKey: modifiers.ctrl ?? false,
    shiftKey: modifiers.shift ?? false,
    target: null,
    preventDefault: () => undefined,
    stopPropagation: () => undefined,
  })
}

beforeEach(() => {
  clearPins()
})

afterEach(() => {
  for (const container of containers.splice(0)) {
    render(null, container)
  }
  clearPins()
})

describe('useKeeperPinShortcuts — RFC-0027 PR-γ-2', () => {
  it('registers 5 shortcuts on mount (4 promote + 1 unpin)', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    const ids = manager.getAll().map(s => s.id).sort()
    expect(ids).toEqual([
      'ide.pin.promote-1',
      'ide.pin.promote-2',
      'ide.pin.promote-3',
      'ide.pin.promote-4',
      'ide.pin.unpin-head',
    ])
  })

  it('disposes all 5 shortcuts on unmount', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    const container = await mountHost(manager)
    expect(manager.getAll().length).toBe(5)
    await unmount(container, manager)
    expect(manager.getAll().length).toBe(0)
  })

  it('Mod+Shift+2 dispatch promotes the slot-2 entry to head', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    pinKeeper('a')
    pinKeeper('b')
    pinKeeper('c') // post-seed order: [c, b, a]; slot-2 = b

    const matched = fireChord(manager, '2', { meta: true, shift: true })

    expect(matched).toBe(true)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['b', 'c', 'a'])
  })

  it('Mod+Shift+W dispatch unpins the head entry', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    pinKeeper('a')
    pinKeeper('b') // head = b

    const matched = fireChord(manager, 'w', { meta: true, shift: true })

    expect(matched).toBe(true)
    expect(pinnedKeepers.value.entries.map(e => e.keeperName)).toEqual(['a'])
  })

  it('Mod+1 (without Shift) does NOT match — exact-match chord policy', async () => {
    // RFC-0012 §4 reserves Mod+1 for ide.tab.switch.1. Our chord is
    // Mod+Shift+1; chordMatches() rejects Mod+1 because wantsShift=true
    // but event.shiftKey=false.
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    pinKeeper('a')
    pinKeeper('b')

    const matched = fireChord(manager, '1', { meta: true, shift: false })

    expect(matched).toBe(false)
  })

  it('Mod+W (without Shift) does NOT match the unpin chord', async () => {
    // Mod+W is RFC-0012 §4 ide.tab.close; ours is Mod+Shift+W.
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    pinKeeper('a')
    pinKeeper('b')

    const matched = fireChord(manager, 'w', { meta: true, shift: false })

    expect(matched).toBe(false)
    expect(pinnedKeepers.value.entries.length).toBe(2)
  })

  it('Mod+Shift+5 is unmatched (only slots 1..4 are bound)', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    pinKeeper('a')
    const matched = fireChord(manager, '5', { meta: true, shift: true })
    expect(matched).toBe(false)
  })

  it('description and aria-keyshortcut format are platform-aware', async () => {
    const manager = createKeyboardShortcutManager({ platform: 'mac' })
    await mountHost(manager)
    const promote2 = manager.getById('ide.pin.promote-2')!
    expect(promote2.description).toBe('Promote pinned keeper #2 to head')
    expect(manager.formatAria(promote2.chord)).toBe('Meta+Shift+2')
    expect(manager.formatChord(promote2.chord)).toBe('⌘+Shift+2')

    const winManager = createKeyboardShortcutManager({ platform: 'win' })
    expect(winManager.formatChord(promote2.chord)).toBe('Ctrl+Shift+2')
  })
})
