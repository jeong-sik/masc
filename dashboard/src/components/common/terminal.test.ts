import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Terminal } from './terminal'

describe('Terminal', () => {
  it('renders log role', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [] }), container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('renders empty state when no lines', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [] }), container)
    expect(container.textContent).toContain('출력 없음')
  })

  it('renders lines', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [{ text: 'hello' }, { text: 'world' }] }), container)
    expect(container.textContent).toContain('hello')
    expect(container.textContent).toContain('world')
  })

  it('renders prompt', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [], prompt: '$ ' }), container)
    expect(container.textContent).toContain('$ ')
  })

  it('does not render prompt when empty', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [], prompt: '' }), container)
    expect(container.querySelectorAll('[data-terminal] > div').length).toBe(1)
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [] }), container)
    const el = container.querySelector('[role="log"]')
    expect(el?.getAttribute('aria-label')).toBe('에이전트 터미널')
  })

  it('applies custom chrome props', () => {
    const container = document.createElement('div')
    render(h(Terminal, {
      lines: [],
      ariaLabel: 'Keeper shell terminal',
      className: 'custom-terminal-shell',
      emptyText: 'waiting for keeper shell output',
    }), container)
    const el = container.querySelector('[role="log"]')
    expect(el?.getAttribute('aria-label')).toBe('Keeper shell terminal')
    expect(el?.className).toBe('custom-terminal-shell')
    expect(container.textContent).toContain('waiting for keeper shell output')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [], testId: 'term-1' }), container)
    expect(container.querySelector('[data-testid="term-1"]')).not.toBeNull()
  })

  it('renders stream tone classes', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [{ text: 'stderr line', tone: 'err' }] }), container)
    const line = container.querySelector('.term-line.is-err')
    expect(line?.textContent).toContain('stderr line')
  })

  it('parses ANSI color codes', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [{ text: '\x1b[31merror\x1b[0m ok' }] }), container)
    const spans = container.querySelectorAll('span')
    const colored = Array.from(spans).filter(s => s.style.color)
    expect(colored.length).toBeGreaterThan(0)
  })

  it('parses ANSI bold', () => {
    const container = document.createElement('div')
    render(h(Terminal, { lines: [{ text: '\x1b[1mbold\x1b[0m' }] }), container)
    const spans = container.querySelectorAll('span')
    const bold = Array.from(spans).find(s => s.style.fontWeight === '600')
    expect(bold).toBeDefined()
  })
})
