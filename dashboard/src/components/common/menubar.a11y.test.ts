// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Menubar, MenubarItem } from './menubar'

describe('Menubar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders with role="menubar" and aria-label', () => {
    render(
      html`
        <${Menubar} aria-label="Main menu">
          <${MenubarItem}>File<//>
          <${MenubarItem}>Edit<//>
        <//>
      `,
      container,
    )
    const menubar = container.querySelector('[role="menubar"]')
    expect(menubar).not.toBeNull()
    expect(menubar?.getAttribute('aria-label')).toBe('Main menu')
  })

  it('items have role="menuitem"', () => {
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem}>A<//>
          <${MenubarItem}>B<//>
        <//>
      `,
      container,
    )
    const items = container.querySelectorAll('[role="menuitem"]')
    expect(items.length).toBe(2)
  })

  it('cycles focus with ArrowRight and ArrowLeft', async () => {
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem}>A<//>
          <${MenubarItem}>B<//>
          <${MenubarItem}>C<//>
        <//>
      `,
      container,
    )
    const menubar = container.querySelector('[role="menubar"]') as HTMLElement
    menubar.focus()
    await new Promise((r) => setTimeout(r, 0))

    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('B')

    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('A')
  })

  it('wraps from last to first with ArrowRight', async () => {
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem}>A<//>
          <${MenubarItem}>B<//>
        <//>
      `,
      container,
    )
    const menubar = container.querySelector('[role="menubar"]') as HTMLElement
    menubar.focus()
    await new Promise((r) => setTimeout(r, 0))

    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('B')

    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('A')
  })

  it('jumps to first with Home and last with End', async () => {
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem}>A<//>
          <${MenubarItem}>B<//>
          <${MenubarItem}>C<//>
        <//>
      `,
      container,
    )
    const menubar = container.querySelector('[role="menubar"]') as HTMLElement
    menubar.focus()
    await new Promise((r) => setTimeout(r, 0))

    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    menubar.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('C')

    menubar.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('A')

    menubar.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    active = container.querySelector('[role="menuitem"][tabindex="0"]') as HTMLButtonElement
    expect(active?.textContent?.trim()).toBe('C')
  })

  it('calls onClick and sets focus on click', () => {
    const onClick = vi.fn()
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem} onClick=${onClick}>Click me<//>
        <//>
      `,
      container,
    )
    const item = container.querySelector('[role="menuitem"]') as HTMLButtonElement
    item.click()
    expect(onClick).toHaveBeenCalled()
    expect(item.getAttribute('tabindex')).toBe('0')
  })

  it('respects disabled state', () => {
    render(
      html`
        <${Menubar} aria-label="M">
          <${MenubarItem} disabled>Disabled<//>
          <${MenubarItem}>Enabled<//>
        <//>
      `,
      container,
    )
    const disabled = container.querySelectorAll('[role="menuitem"]')[0] as HTMLButtonElement
    expect(disabled.disabled).toBe(true)
  })
})
