// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorKeyboardShortcuts,
  mapKeyToConnectorId,
  shouldSkipShortcut,
  _testResetShortcutState,
  _testIsCheatsheetOpen,
} from './connector-keyboard-shortcuts'

describe('mapKeyToConnectorId', () => {
  it('maps 1..4 to discord/imessage/slack/telegram', () => {
    expect(mapKeyToConnectorId('1')).toBe('discord')
    expect(mapKeyToConnectorId('2')).toBe('imessage')
    expect(mapKeyToConnectorId('3')).toBe('slack')
    expect(mapKeyToConnectorId('4')).toBe('telegram')
  })

  it('returns null for out-of-range digits', () => {
    expect(mapKeyToConnectorId('0')).toBeNull()
    expect(mapKeyToConnectorId('5')).toBeNull()
    expect(mapKeyToConnectorId('9')).toBeNull()
  })

  it('returns null for non-digit keys', () => {
    expect(mapKeyToConnectorId('a')).toBeNull()
    expect(mapKeyToConnectorId('?')).toBeNull()
    expect(mapKeyToConnectorId(' ')).toBeNull()
    expect(mapKeyToConnectorId('Enter')).toBeNull()
    expect(mapKeyToConnectorId('')).toBeNull()
  })

  it('returns null for multi-char keys like "11"', () => {
    expect(mapKeyToConnectorId('11')).toBeNull()
    expect(mapKeyToConnectorId('1a')).toBeNull()
  })
})

describe('shouldSkipShortcut', () => {
  it('skips when target is INPUT', () => {
    const inp = document.createElement('input')
    expect(shouldSkipShortcut(inp)).toBe(true)
  })

  it('skips when target is TEXTAREA', () => {
    const ta = document.createElement('textarea')
    expect(shouldSkipShortcut(ta)).toBe(true)
  })

  it('skips when target is SELECT', () => {
    const sel = document.createElement('select')
    expect(shouldSkipShortcut(sel)).toBe(true)
  })

  it('skips when target is contentEditable', () => {
    const div = document.createElement('div')
    div.setAttribute('contenteditable', 'true')
    // happy-dom reflects the attribute into the property
    Object.defineProperty(div, 'isContentEditable', { value: true })
    expect(shouldSkipShortcut(div)).toBe(true)
  })

  it('does not skip for a plain div', () => {
    const div = document.createElement('div')
    expect(shouldSkipShortcut(div)).toBe(false)
  })

  it('does not skip when target is null', () => {
    expect(shouldSkipShortcut(null)).toBe(false)
  })
})

describe('ConnectorKeyboardShortcuts DOM', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetShortcutState()
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    _testResetShortcutState()
  })

  // useEffect runs on a microtask after mount, so we always flush twice
  // before firing events that rely on the window listener being attached.
  const flushMount = async () => {
    await Promise.resolve()
    await Promise.resolve()
  }

  it('renders nothing by default (cheatsheet closed)', () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    expect(container.querySelector('[data-connector-shortcut-cheatsheet]')).toBeNull()
  })

  it('opens cheatsheet on "?" keydown, closes on second "?"', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '?' }))
    expect(_testIsCheatsheetOpen()).toBe(true)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '?' }))
    expect(_testIsCheatsheetOpen()).toBe(false)
  })

  it('closes cheatsheet on Escape', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '?' }))
    expect(_testIsCheatsheetOpen()).toBe(true)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(_testIsCheatsheetOpen()).toBe(false)
  })

  it('ignores "1" when focus is inside an input (typing, not navigating)', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    const input = document.createElement('input')
    document.body.appendChild(input)
    try {
      // Scroll target card exists but the keystroke should NOT scroll because the
      // input is the event target — simulate by dispatching on the input.
      const card = document.createElement('div')
      card.id = 'connector-card-discord'
      document.body.appendChild(card)
      let scrolled = false
      card.scrollIntoView = () => { scrolled = true }
      input.dispatchEvent(new KeyboardEvent('keydown', { key: '1', bubbles: true }))
      expect(scrolled).toBe(false)
      document.body.removeChild(card)
    } finally {
      document.body.removeChild(input)
    }
  })

  it('ignores modified keys (cmd/ctrl/alt + 1)', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    const card = document.createElement('div')
    card.id = 'connector-card-discord'
    document.body.appendChild(card)
    let scrolled = false
    card.scrollIntoView = () => { scrolled = true }
    try {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: '1', metaKey: true }))
      expect(scrolled).toBe(false)
      window.dispatchEvent(new KeyboardEvent('keydown', { key: '1', ctrlKey: true }))
      expect(scrolled).toBe(false)
    } finally {
      document.body.removeChild(card)
    }
  })

  it('scrolls to connector card when digit key is pressed', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    const card = document.createElement('div')
    card.id = 'connector-card-slack'
    document.body.appendChild(card)
    let scrolledTo: ScrollIntoViewOptions | boolean | undefined
    card.scrollIntoView = ((opts: ScrollIntoViewOptions | boolean | undefined) => {
      scrolledTo = opts
    }) as HTMLElement['scrollIntoView']
    try {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: '3' }))
      expect(scrolledTo).toBeDefined()
    } finally {
      document.body.removeChild(card)
    }
  })

  it('cheatsheet lists all known connectors and the "?" toggle key', async () => {
    render(html`<${ConnectorKeyboardShortcuts} />`, container)
    await flushMount()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '?' }))
    // Signal update → re-render is scheduled on the microtask queue.
    await Promise.resolve()
    await Promise.resolve()
    const sheet = container.querySelector('[data-connector-shortcut-cheatsheet]')
    expect(sheet).toBeTruthy()
    const text = sheet!.textContent ?? ''
    expect(text).toContain('discord')
    expect(text).toContain('imessage')
    expect(text).toContain('slack')
    expect(text).toContain('telegram')
    expect(text).toContain('?')
  })
})
