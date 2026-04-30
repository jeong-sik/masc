// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Toolbar, ToolbarButton, ToolbarSeparator } from './toolbar'

describe('Toolbar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>Cut<//>`,
        html`<${ToolbarButton}>Copy<//>`,
        html`<${ToolbarButton}>Paste<//>`,
      ]}<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has toolbar role and aria-orientation', () => {
    render(
      html`<${Toolbar} aria-label="Actions" orientation="vertical">${[
        html`<${ToolbarButton}>A<//>`,
      ]}<//>`,
      container,
    )
    const toolbar = container.querySelector('[role="toolbar"]')
    expect(toolbar).not.toBeNull()
    expect(toolbar?.getAttribute('aria-label')).toBe('Actions')
    expect(toolbar?.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('only the first button has tabindex=0 initially', () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>A<//>`,
        html`<${ToolbarButton}>B<//>`,
        html`<${ToolbarButton}>C<//>`,
      ]}<//>`,
      container,
    )
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]!.getAttribute('tabindex')).toBe('0')
    expect(buttons[1]!.getAttribute('tabindex')).toBe('-1')
    expect(buttons[2]!.getAttribute('tabindex')).toBe('-1')
  })

  it('moves focus with ArrowRight in horizontal mode', async () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>A<//>`,
        html`<${ToolbarButton}>B<//>`,
        html`<${ToolbarButton}>C<//>`,
      ]}<//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const buttons = container.querySelectorAll('button')
    ;(buttons[0]! as HTMLButtonElement).focus()

    buttons[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(buttons[0]!.getAttribute('tabindex')).toBe('-1')
    expect(buttons[1]!.getAttribute('tabindex')).toBe('0')
  })

  it('moves focus with ArrowLeft in horizontal mode', async () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>A<//>`,
        html`<${ToolbarButton}>B<//>`,
        html`<${ToolbarButton}>C<//>`,
      ]}<//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const buttons = container.querySelectorAll('button')
    ;(buttons[0]! as HTMLButtonElement).focus()

    buttons[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    buttons[1]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(buttons[0]!.getAttribute('tabindex')).toBe('0')
  })

  it('jumps to first and last with Home and End', async () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>A<//>`,
        html`<${ToolbarButton}>B<//>`,
        html`<${ToolbarButton}>C<//>`,
      ]}<//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const buttons = container.querySelectorAll('button')
    ;(buttons[0]! as HTMLButtonElement).focus()

    buttons[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))

    buttons[1]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Home', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(buttons[0]!.getAttribute('tabindex')).toBe('0')

    buttons[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'End', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(buttons[2]!.getAttribute('tabindex')).toBe('0')
  })

  it('separator has role separator and aria-orientation', () => {
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton}>A<//>`,
        html`<${ToolbarSeparator} />`,
        html`<${ToolbarButton}>B<//>`,
      ]}<//>`,
      container,
    )
    const sep = container.querySelector('[role="separator"]')
    expect(sep).not.toBeNull()
    expect(sep?.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('calls onClick when button is clicked', async () => {
    const onClick = vi.fn()
    render(
      html`<${Toolbar} aria-label="Actions">${[
        html`<${ToolbarButton} onClick=${onClick}>Action<//>`,
      ]}<//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onClick).toHaveBeenCalledOnce()
  })
})
