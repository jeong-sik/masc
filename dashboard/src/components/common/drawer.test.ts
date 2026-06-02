// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Drawer, panelCls, summarizeDrawerPosition } from './drawer'

describe('summarizeDrawerPosition', () => {
  it('summarizes horizontal positions', () => {
    expect(summarizeDrawerPosition('left')).toEqual({
      position: 'left',
      axis: 'horizontal',
      edge: 'left',
    })
    expect(summarizeDrawerPosition('right')).toEqual({
      position: 'right',
      axis: 'horizontal',
      edge: 'right',
    })
  })

  it('summarizes vertical positions', () => {
    expect(summarizeDrawerPosition('top')).toEqual({
      position: 'top',
      axis: 'vertical',
      edge: 'top',
    })
    expect(summarizeDrawerPosition('bottom')).toEqual({
      position: 'bottom',
      axis: 'vertical',
      edge: 'bottom',
    })
  })
})

describe('panelCls', () => {
  it('bounds side drawers to the viewport width', () => {
    expect(panelCls('right')).toContain('max-w-[calc(100vw-1rem)]')
    expect(panelCls('left')).toContain('max-w-[calc(100vw-1rem)]')
  })

  it('bounds top and bottom drawers to the viewport height', () => {
    expect(panelCls('top')).toContain('max-h-[calc(100vh-1rem)]')
    expect(panelCls('bottom')).toContain('max-h-[calc(100vh-1rem)]')
  })
})

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

  it('uses a stable generated title id for aria-labelledby', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T' }, 'Body'), container)
    const dialog = container.querySelector('[role="dialog"]')
    const title = container.querySelector('[data-drawer-title]')
    expect(dialog?.getAttribute('aria-labelledby')).toBe(title?.getAttribute('id'))
  })

  it('does not reuse title ids across multiple drawers', () => {
    const container = document.createElement('div')
    render(
      h('div', null, [
        h(Drawer, { open: true, onClose: vi.fn(), title: 'A' }, 'A body'),
        h(Drawer, { open: true, onClose: vi.fn(), title: 'B' }, 'B body'),
      ]),
      container,
    )
    const ids = Array.from(container.querySelectorAll('[data-drawer-title]'))
      .map((el) => el.getAttribute('id'))
    expect(new Set(ids).size).toBe(2)
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

  it('publishes drawer position metadata', () => {
    const container = document.createElement('div')
    render(h(Drawer, { open: true, onClose: vi.fn(), title: 'T', position: 'bottom' }, 'Body'), container)
    const root = container.querySelector('[data-drawer]')
    const panel = container.querySelector('[data-drawer-panel]')
    expect(root?.getAttribute('data-drawer-open')).toBe('true')
    expect(root?.getAttribute('data-drawer-position')).toBe('bottom')
    expect(root?.getAttribute('data-drawer-axis')).toBe('vertical')
    expect(root?.getAttribute('data-drawer-edge')).toBe('bottom')
    expect(panel?.getAttribute('data-drawer-panel-position')).toBe('bottom')
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
