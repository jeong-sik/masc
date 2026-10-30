// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CommandBar } from './command-bar'

describe('CommandBar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const actions = [
    { id: 'a1', title: 'Navigate Home', handler: vi.fn() },
    { id: 'a2', title: 'Open Settings', handler: vi.fn() },
    { id: 'a3', title: 'Run GC', handler: vi.fn() },
  ]

  it('renders accessibly', async () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=combobox', () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    const input = container.querySelector('input')
    expect(input).not.toBeNull()
    expect(input?.getAttribute('role')).toBe('combobox')
  })

  it('opens listbox on focus', async () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    await new Promise((r) => setTimeout(r, 0))
    const listbox = container.querySelector('[role="listbox"]')
    expect(listbox).not.toBeNull()
  })

  it('has correct aria-expanded and aria-controls', async () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.getAttribute('aria-expanded')).toBe('false')
    input.focus()
    await new Promise((r) => setTimeout(r, 0))
    expect(input?.getAttribute('aria-expanded')).toBe('true')
    expect(input?.getAttribute('aria-controls')).toBeTruthy()
  })

  it('filters results and updates listbox accessibly', async () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    input.value = 'settings'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))

    const options = container.querySelectorAll('[role="option"]')
    expect(options.length).toBeGreaterThan(0)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('handles keyboard navigation with aria-activedescendant', async () => {
    render(html`<${CommandBar} actions=${actions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    await new Promise((r) => setTimeout(r, 0))

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))

    const activeId = input.getAttribute('aria-activedescendant')
    expect(activeId).toBeTruthy()
    expect(container.querySelector(`#${CSS.escape(activeId!)}`)).not.toBeNull()
  })

  it('calls handler on Enter', async () => {
    const handler = vi.fn()
    const localActions = [{ id: 'x1', title: 'Test', handler }]
    render(html`<${CommandBar} actions=${localActions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    await new Promise((r) => setTimeout(r, 0))

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))

    expect(handler).toHaveBeenCalled()
  })

  it('calls handler on item click', async () => {
    const handler = vi.fn()
    const localActions = [{ id: 'x1', title: 'Test', handler }]
    render(html`<${CommandBar} actions=${localActions} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    await new Promise((r) => setTimeout(r, 0))

    const item = container.querySelector('[role="option"]') as HTMLElement
    item.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))

    expect(handler).toHaveBeenCalled()
  })
})
