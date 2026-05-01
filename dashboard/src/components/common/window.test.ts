// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Window } from './window'

describe('Window', () => {
  it('renders nothing when closed', () => {
    const container = document.createElement('div')
    render(h(Window, { open: false, onClose: () => {}, 'aria-label': 'win' }, 'content'), container)
    expect(container.textContent).toBe('')
  })

  it('renders dialog role when open', () => {
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose: () => {}, 'aria-label': 'win' }, 'content'), container)
    expect(container.querySelector('[role="dialog"]')).not.toBeNull()
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose: () => {}, 'aria-label': 'win' }, 'hello'), container)
    expect(container.textContent).toContain('hello')
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose: () => {}, 'aria-label': 'my dialog' }, 'x'), container)
    const dialog = container.querySelector('[role="dialog"]')
    expect(dialog?.getAttribute('aria-label')).toBe('my dialog')
  })

  it('applies aria-modal', () => {
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose: () => {}, 'aria-label': 'win' }, 'x'), container)
    const dialog = container.querySelector('[role="dialog"]')
    expect(dialog?.getAttribute('aria-modal')).toBe('true')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose: () => {}, 'aria-label': 'win', class: 'my-win' }, 'x'), container)
    const dialog = container.querySelector('[role="dialog"]')
    expect(dialog?.classList.contains('my-win')).toBe(true)
  })

  it('calls onClose on Escape', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose, 'aria-label': 'win' }, 'x'), container)
    await new Promise((r) => setTimeout(r, 10))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Escape'
    document.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })

  it('calls onClose on Alt+F4', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(Window, { open: true, onClose, 'aria-label': 'win' }, 'x'), container)
    await new Promise((r) => setTimeout(r, 10))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'F4'
    ;(ev as any).altKey = true
    document.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })
})
