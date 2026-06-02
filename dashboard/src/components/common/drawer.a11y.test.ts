// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Drawer } from './drawer'

describe('Drawer a11y', () => {
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
    render(
      html`<${Drawer} open title="Settings" onClose=${vi.fn()}>Content<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has dialog role and aria-modal when open', () => {
    render(
      html`<${Drawer} open title="Settings" onClose=${vi.fn()}>Content<//>`,
      container,
    )
    const dialog = container.querySelector('[role="dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.getAttribute('aria-modal')).toBe('true')
  })

  it('is not rendered when closed', () => {
    render(
      html`<${Drawer} open=${false} title="Settings" onClose=${vi.fn()}>Content<//>`,
      container,
    )
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('calls onClose when Escape is pressed', async () => {
    const onClose = vi.fn()
    const addListenerSpy = vi.spyOn(document, 'addEventListener')
    render(
      html`<${Drawer} open title="Settings" onClose=${onClose}>Content<//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const call = addListenerSpy.mock.calls.find(
      (c) => c[0] === 'keydown' && typeof c[1] === 'function',
    )
    const handler = call?.[1] as EventListener
    handler(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(onClose).toHaveBeenCalledOnce()
    addListenerSpy.mockRestore()
  })

  it('calls onClose when backdrop is clicked', async () => {
    const onClose = vi.fn()
    render(
      html`<${Drawer} open title="Settings" onClose=${onClose}>Content<//>`,
      container,
    )
    const backdrop = container.querySelector('[role="presentation"]') as HTMLElement
    backdrop?.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })

  it('does not call onClose when panel is clicked', async () => {
    const onClose = vi.fn()
    render(
      html`<${Drawer} open title="Settings" onClose=${onClose}>Content<//>`,
      container,
    )
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    panel?.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).not.toHaveBeenCalled()
  })

  it('supports left position', () => {
    render(
      html`<${Drawer} open title="Left" position="left" onClose=${vi.fn()}>Content<//>`,
      container,
    )
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('left-0')).toBe(true)
  })

  it('supports top position', () => {
    render(
      html`<${Drawer} open title="Top" position="top" onClose=${vi.fn()}>Content<//>`,
      container,
    )
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('top-0')).toBe(true)
    expect(panel?.classList.contains('h-64')).toBe(true)
  })
})
