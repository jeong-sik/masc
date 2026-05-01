import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { KeyboardShortcut } from './keyboard-shortcut'

describe('KeyboardShortcut', () => {
  it('renders empty message when no shortcuts', () => {
    const container = document.createElement('div')
    render(h(KeyboardShortcut, { shortcuts: [] }), container)
    expect(container.textContent).toContain('등록된 단축키가 없습니다')
  })

  it('renders shortcut rows', () => {
    const container = document.createElement('div')
    const shortcuts = [
      { id: 's1', keys: ['Ctrl', 'S'], description: 'Save' },
      { id: 's2', keys: ['Esc'], description: 'Close' },
    ]
    render(h(KeyboardShortcut, { shortcuts }), container)
    expect(container.textContent).toContain('Save')
    expect(container.textContent).toContain('Close')
  })

  it('renders keys with separators', () => {
    const container = document.createElement('div')
    const shortcuts = [{ id: 's1', keys: ['Ctrl', 'S'], description: 'Save' }]
    render(h(KeyboardShortcut, { shortcuts }), container)
    expect(container.textContent).toContain('Ctrl')
    expect(container.textContent).toContain('S')
    expect(container.textContent).toContain('+')
  })

  it('applies conflict styling', () => {
    const container = document.createElement('div')
    const shortcuts = [{ id: 's1', keys: ['A'], description: 'Action', conflict: true }]
    render(h(KeyboardShortcut, { shortcuts }), container)
    const row = container.querySelector('[role="listitem"]')
    expect(row?.className).toContain('bg-[var(--error-10)]')
  })

  it('renders context when provided', () => {
    const container = document.createElement('div')
    const shortcuts = [{ id: 's1', keys: ['A'], description: 'Action', context: 'Global' }]
    render(h(KeyboardShortcut, { shortcuts }), container)
    expect(container.textContent).toContain('Global')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(KeyboardShortcut, { shortcuts: [], testId: 'ks-1' }), container)
    expect(container.querySelector('[data-testid="ks-1"]')).not.toBeNull()
  })
})
