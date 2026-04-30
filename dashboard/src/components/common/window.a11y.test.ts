// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Window } from './window'

describe('Window a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when open', async () => {
    render(html`<${Window} open aria-label="Settings" onClose=${() => {}}>Content<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role="dialog" and aria-modal="true"', () => {
    render(html`<${Window} open aria-label="Settings" onClose=${() => {}}>Content<//>`, container)
    const dialog = container.querySelector('[role="dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.getAttribute('aria-modal')).toBe('true')
    expect(dialog?.getAttribute('aria-label')).toBe('Settings')
  })

  it('is not rendered when closed', () => {
    render(html`<${Window} open=${false} aria-label="Settings" onClose=${() => {}}>Content<//>`, container)
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('calls onClose on Escape', async () => {
    const onClose = vi.fn()
    render(html`<${Window} open aria-label="Settings" onClose=${onClose}>Content<//>`, container)
    await new Promise((r) => setTimeout(r, 0))
    const dialog = container.querySelector('[role="dialog"]') as HTMLElement
    dialog.focus()

    dialog.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalled()
  })

  it('calls onClose on Alt+F4', async () => {
    const onClose = vi.fn()
    render(html`<${Window} open aria-label="Settings" onClose=${onClose}>Content<//>`, container)
    await new Promise((r) => setTimeout(r, 0))
    const dialog = container.querySelector('[role="dialog"]') as HTMLElement
    dialog.focus()

    const ev = new KeyboardEvent('keydown', { key: 'F4', bubbles: true })
    Object.defineProperty(ev, 'altKey', { value: true })
    dialog.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalled()
  })

  it('auto-focuses when opened', async () => {
    render(html`<${Window} open aria-label="Settings" onClose=${() => {}}>Content<//>`, container)
    await new Promise((r) => setTimeout(r, 50))
    const dialog = container.querySelector('[role="dialog"]') as HTMLElement
    expect(document.activeElement).toBe(dialog)
  })
})
