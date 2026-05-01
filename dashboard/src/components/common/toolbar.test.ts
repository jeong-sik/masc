// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Toolbar, ToolbarButton, ToolbarSeparator } from './toolbar'

describe('Toolbar', () => {
  it('renders toolbar role', () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' }, h(ToolbarButton, {}, 'A')),
      container,
    )
    expect(container.querySelector('[role="toolbar"]')).not.toBeNull()
  })

  it('renders buttons', () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, {}, 'A'),
        h(ToolbarButton, {}, 'B'),
      ),
      container,
    )
    const btns = container.querySelectorAll('button')
    expect(btns.length).toBe(2)
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
  })

  it('applies aria-orientation', () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools', orientation: 'vertical' },
        h(ToolbarButton, {}, 'A'),
      ),
      container,
    )
    const bar = container.querySelector('[role="toolbar"]')
    expect(bar?.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('calls onClick on button click', async () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, { onClick }, 'A'),
      ),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onClick).toHaveBeenCalledOnce()
  })

  it('has only first button tabindex=0 initially', async () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, {}, 'A'),
        h(ToolbarButton, {}, 'B'),
      ),
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const btns = container.querySelectorAll('button')
    expect(btns[0]?.getAttribute('tabindex')).toBe('0')
    expect(btns[1]?.getAttribute('tabindex')).toBe('-1')
  })

  it('moves focus on ArrowRight', async () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, {}, 'A'),
        h(ToolbarButton, {}, 'B'),
      ),
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const bar = container.querySelector('[role="toolbar"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'ArrowRight'
    bar.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    const btns = container.querySelectorAll('button')
    expect(btns[0]?.getAttribute('tabindex')).toBe('-1')
    expect(btns[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('renders separator role', () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, {}, 'A'),
        h(ToolbarSeparator, {}),
        h(ToolbarButton, {}, 'B'),
      ),
      container,
    )
    expect(container.querySelector('[role="separator"]')).not.toBeNull()
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools', class: 'my-bar' },
        h(ToolbarButton, {}, 'A'),
      ),
      container,
    )
    const bar = container.querySelector('[role="toolbar"]')
    expect(bar?.classList.contains('my-bar')).toBe(true)
  })

  it('applies aria-pressed to button', async () => {
    const container = document.createElement('div')
    render(
      h(Toolbar, { 'aria-label': 'tools' },
        h(ToolbarButton, { 'aria-pressed': true }, 'A'),
      ),
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const btn = container.querySelector('button')
    expect(btn?.getAttribute('aria-pressed')).toBe('true')
  })
})
