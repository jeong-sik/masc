// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { KeyboardShortcut } from './keyboard-shortcut'

describe('KeyboardShortcut a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeShortcuts = (): import('./keyboard-shortcut').ShortcutItem[] => [
    { id: 's1', keys: ['Ctrl', 'K'], description: 'Open command palette' },
    { id: 's2', keys: ['Esc'], description: 'Close dialog', context: 'dialog' },
    { id: 's3', keys: ['Ctrl', 'K'], description: 'Quick search', conflict: true },
  ]

  it('renders accessibly with shortcuts', async () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${KeyboardShortcut} shortcuts=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has list role', () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    expect(container.querySelector('[role="list"]')).not.toBeNull()
  })

  it('renders listitems', () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)
  })

  it('renders key chords', () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    expect(container.textContent).toContain('Ctrl')
    expect(container.textContent).toContain('K')
    expect(container.textContent).toContain('Esc')
  })

  it('renders context label', () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    expect(container.textContent).toContain('dialog')
  })

  it('highlights conflict row', () => {
    render(html`<${KeyboardShortcut} shortcuts=${makeShortcuts()} />`, container)
    const items = container.querySelectorAll('[role="listitem"]')
    const conflict = Array.from(items).find((el) =>
      el.textContent?.includes('Quick search'),
    )
    expect(conflict).not.toBeNull()
    expect(conflict?.className.includes('bg-[var(--error-10)]')).toBe(true)
  })
})
