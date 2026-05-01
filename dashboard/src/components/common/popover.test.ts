// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Popover } from './popover'

describe('Popover', () => {
  it('renders trigger child', () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    expect(container.textContent).toContain('Open')
  })

  it('opens panel on trigger click', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.textContent).toContain('Panel')
  })

  it('closes panel on Escape', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('closes panel on outside click', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    document.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })

  it('does not close on panel click', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    panel?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[role="dialog"]')).not.toBeNull()
  })

  it('sets aria-haspopup and aria-expanded on trigger', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    expect(btn.getAttribute('aria-haspopup')).toBe('dialog')
    expect(btn.getAttribute('aria-expanded')).toBe('false')
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('aria-expanded')).toBe('true')
  })

  it('sets aria-controls when open', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    expect(btn.getAttribute('aria-controls')).toBeNull()
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('aria-controls')).toBeTruthy()
  })

  it('applies bottom placement class by default', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open') }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('top-full')).toBe(true)
    expect(panel?.classList.contains('mt-1')).toBe(true)
  })

  it('applies top placement class', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open'), placement: 'top' }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    const panel = container.querySelector('[role="dialog"]') as HTMLElement
    expect(panel?.classList.contains('bottom-full')).toBe(true)
    expect(panel?.classList.contains('mb-1')).toBe(true)
  })

  it('applies testId to panel', async () => {
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open'), testId: 'pop-1' }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[data-testid="pop-1"]')).not.toBeNull()
  })

  it('calls onClose when closing', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(
      h(Popover, { trigger: h('button', null, 'Open'), onClose }, 'Panel'),
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })
})
