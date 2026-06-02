// Pure TS unit tests for KeyboardShortcutManager. No DOM.
import { describe, it, expect, vi } from 'vitest'
import {
  createKeyboardShortcutManager,
  type ShortcutKeyEvent,
} from './keyboard-shortcuts'

function makeEvent(opts: Partial<ShortcutKeyEvent> & { key: string }): ShortcutKeyEvent {
  let prevented = false
  let stopped = false
  return {
    key: opts.key,
    metaKey: opts.metaKey,
    ctrlKey: opts.ctrlKey,
    shiftKey: opts.shiftKey,
    altKey: opts.altKey,
    target: opts.target ?? null,
    preventDefault() {
      prevented = true
    },
    stopPropagation() {
      stopped = true
    },
    get _prevented() {
      return prevented
    },
    get _stopped() {
      return stopped
    },
  } as ShortcutKeyEvent & { readonly _prevented: boolean; readonly _stopped: boolean }
}

describe('createKeyboardShortcutManager — register / unregister', () => {
  it('register returns dispose; getById round-trips', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    const dispose = m.register({
      id: 'ide.toggle-sidebar',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: 'toggle sidebar',
      scope: 'global',
      action,
    })
    expect(m.getById('ide.toggle-sidebar')).toBeDefined()
    dispose()
    expect(m.getById('ide.toggle-sidebar')).toBeUndefined()
  })

  it('unregisterAll(prefix) removes only matching ids', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    m.register({
      id: 'ide.tab.close',
      chord: { key: 'w', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    m.register({
      id: 'editor.format',
      chord: { key: 'l', modifiers: ['Mod', 'Shift'] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    m.unregisterAll('ide.')
    expect(m.getById('ide.tab.close')).toBeUndefined()
    expect(m.getById('editor.format')).toBeDefined()
  })

  it('duplicate id replaces and warns', () => {
    const warnings: string[] = []
    const m = createKeyboardShortcutManager({
      platform: 'mac',
      warn: (msg) => warnings.push(msg),
    })
    m.register({
      id: 'x',
      chord: { key: 'a', modifiers: [] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    m.register({
      id: 'x',
      chord: { key: 'b', modifiers: [] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    expect(warnings).toHaveLength(1)
    expect(warnings[0]).toContain('already registered')
  })
})

describe('createKeyboardShortcutManager — chord matching (mac platform)', () => {
  it('Meta+B matches Mod+B chord', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'sidebar',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(m.dispatch(makeEvent({ key: 'b', metaKey: true }))).toBe(true)
    expect(action).toHaveBeenCalledOnce()
  })

  it('Meta+B does NOT match Mod+Shift+B chord (exact modifier match)', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'b',
      chord: { key: 'b', modifiers: ['Mod', 'Shift'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(m.dispatch(makeEvent({ key: 'b', metaKey: true }))).toBe(false)
    expect(action).not.toHaveBeenCalled()
  })

  it('Ctrl+B does NOT match Mod+B on mac (Mod is Meta there)', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'b',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(m.dispatch(makeEvent({ key: 'b', ctrlKey: true }))).toBe(false)
    expect(action).not.toHaveBeenCalled()
  })

  it('Ctrl+B matches Mod+B on linux', () => {
    const m = createKeyboardShortcutManager({ platform: 'linux' })
    const action = vi.fn()
    m.register({
      id: 'b',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(m.dispatch(makeEvent({ key: 'b', ctrlKey: true }))).toBe(true)
    expect(action).toHaveBeenCalledOnce()
  })
})

describe('createKeyboardShortcutManager — preserveInInputs', () => {
  it('default preserveInInputs=undefined drops shortcuts inside <input>', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'x',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(
      m.dispatch(makeEvent({ key: 'b', metaKey: true, target: { tagName: 'INPUT' } })),
    ).toBe(false)
    expect(action).not.toHaveBeenCalled()
  })

  it('preserveInInputs=true fires inside <input>', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'x',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      preserveInInputs: true,
      action,
    })
    expect(
      m.dispatch(makeEvent({ key: 'b', metaKey: true, target: { tagName: 'INPUT' } })),
    ).toBe(true)
    expect(action).toHaveBeenCalledOnce()
  })

  it('contenteditable counts as input', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const action = vi.fn()
    m.register({
      id: 'x',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action,
    })
    expect(
      m.dispatch(
        makeEvent({ key: 'b', metaKey: true, target: { isContentEditable: true } }),
      ),
    ).toBe(false)
  })
})

describe('createKeyboardShortcutManager — formatChord', () => {
  it('mac uses ⌘ for Mod', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    expect(m.formatChord({ key: 'b', modifiers: ['Mod'] })).toBe('⌘+B')
  })

  it('win/linux uses Ctrl for Mod', () => {
    const m = createKeyboardShortcutManager({ platform: 'linux' })
    expect(m.formatChord({ key: 'b', modifiers: ['Mod'] })).toBe('Ctrl+B')
  })

  it('platform override per call', () => {
    const m = createKeyboardShortcutManager({ platform: 'linux' })
    expect(m.formatChord({ key: 'b', modifiers: ['Mod'] }, 'mac')).toBe('⌘+B')
  })
})

describe('createKeyboardShortcutManager — formatAria', () => {
  it('mac emits Meta+B', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    expect(m.formatAria({ key: 'b', modifiers: ['Mod'] })).toBe('Meta+B')
  })

  it('linux emits Control+B', () => {
    const m = createKeyboardShortcutManager({ platform: 'linux' })
    expect(m.formatAria({ key: 'b', modifiers: ['Mod'] })).toBe('Control+B')
  })

  it('Mod+Shift+B emits in canonical W3C order', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    expect(m.formatAria({ key: 'b', modifiers: ['Mod', 'Shift'] })).toBe('Meta+Shift+B')
  })
})

describe('createKeyboardShortcutManager — priority + last-registered tie-break', () => {
  it('higher priority wins on conflict', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const lo = vi.fn()
    const hi = vi.fn()
    m.register({
      id: 'lo',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      priority: 0,
      action: lo,
    })
    m.register({
      id: 'hi',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      priority: 10,
      action: hi,
    })
    m.dispatch(makeEvent({ key: 'b', metaKey: true }))
    expect(hi).toHaveBeenCalledOnce()
    expect(lo).not.toHaveBeenCalled()
  })

  it('same priority -> last-registered wins', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    const first = vi.fn()
    const last = vi.fn()
    m.register({
      id: 'first',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action: first,
    })
    m.register({
      id: 'last',
      chord: { key: 'b', modifiers: ['Mod'] },
      description: '',
      scope: 'global',
      action: last,
    })
    m.dispatch(makeEvent({ key: 'b', metaKey: true }))
    expect(last).toHaveBeenCalledOnce()
  })
})

describe('createKeyboardShortcutManager — subscribe', () => {
  it('subscriber fires on register / unregister', () => {
    const m = createKeyboardShortcutManager({ platform: 'mac' })
    let count = 0
    const dispose = m.subscribe(() => {
      count += 1
    })
    const undo = m.register({
      id: 'a',
      chord: { key: 'a', modifiers: [] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    expect(count).toBe(1)
    undo()
    expect(count).toBe(2)
    dispose()
    m.register({
      id: 'b',
      chord: { key: 'b', modifiers: [] },
      description: '',
      scope: 'global',
      action: () => {},
    })
    expect(count).toBe(2)
  })
})
