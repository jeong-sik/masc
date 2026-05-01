// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Menubar, MenubarItem } from './menubar'

describe('Menubar', () => {
  it('renders menubar role', () => {
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'menu' },
        h(MenubarItem, {}, 'Item A'),
      ),
      container,
    )
    expect(container.querySelector('[role="menubar"]')).not.toBeNull()
  })

  it('renders menuitems', () => {
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'menu' },
        h(MenubarItem, {}, 'Item A'),
        h(MenubarItem, {}, 'Item B'),
      ),
      container,
    )
    const items = container.querySelectorAll('[role="menuitem"]')
    expect(items.length).toBe(2)
    expect(container.textContent).toContain('Item A')
    expect(container.textContent).toContain('Item B')
  })

  it('calls onClick on item click', async () => {
    const onClick = vi.fn()
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'menu' },
        h(MenubarItem, { onClick }, 'Item A'),
      ),
      container,
    )
    const btn = container.querySelector('[role="menuitem"]') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onClick).toHaveBeenCalledOnce()
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'main menu' },
        h(MenubarItem, {}, 'Item A'),
      ),
      container,
    )
    const bar = container.querySelector('[role="menubar"]')
    expect(bar?.getAttribute('aria-label')).toBe('main menu')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'menu', class: 'my-bar' },
        h(MenubarItem, {}, 'Item A'),
      ),
      container,
    )
    const bar = container.querySelector('[role="menubar"]')
    expect(bar?.classList.contains('my-bar')).toBe(true)
  })

  it('has disabled attribute when disabled', () => {
    const container = document.createElement('div')
    render(
      h(Menubar, { 'aria-label': 'menu' },
        h(MenubarItem, { disabled: true }, 'Item A'),
      ),
      container,
    )
    const btn = container.querySelector('[role="menuitem"]') as HTMLButtonElement
    expect(btn.disabled).toBe(true)
  })
})
