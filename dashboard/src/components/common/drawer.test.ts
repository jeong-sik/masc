// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Drawer } from './drawer'

describe('Drawer', () => {
  it('returns null when closed', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: false, onClose: vi.fn(), title: 'T' }, 'Body'), container)
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('renders dialog when open', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T' }, 'Body'), container)
    expect(container.querySelector('[role="dialog"]')).not.toBeNull()
  })

  it('has aria-modal="true"', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T' }, 'Body'), container)
    const el = container.querySelector('[role="dialog"]')
    expect(el?.getAttribute('aria-modal')).toBe('true')
  })

  it('renders title', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'Settings' }, 'Body'), container)
    expect(container.textContent).toContain('Settings')
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T' }, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('calls onClose when backdrop is clicked', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose, title: 'T' }, 'Body'), container)
    const backdrop = container.querySelector('[role="presentation"]') as HTMLElement
    backdrop?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })

  it('does not call onClose when panel is clicked', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose, title: 'T' }, 'Body'), container)
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    panel?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).not.toHaveBeenCalled()
  })

  it('supports left position', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T', position: 'left' }, 'Body'), container)
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('left-0')).toBe(true)
  })

  it('supports top position', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T', position: 'top' }, 'Body'), container)
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('top-0')).toBe(true)
    expect(panel?.classList.contains('h-64')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T', class: 'extra' }, 'Body'), container)
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('extra')).toBe(true)
  })
})
