import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AlertDialog } from './alert-dialog'

describe('AlertDialog', () => {
  it('returns null when closed', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: false, title: 'T', onClose: vi.fn() }, 'Body'), container)
    expect(container.querySelector('[role="alertdialog"]')).toBeNull()
  })

  it('renders alertdialog when open', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', onClose: vi.fn() }, 'Body'), container)
    expect(container.querySelector('[role="alertdialog"]')).not.toBeNull()
  })

  it('has aria-modal="true"', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', onClose: vi.fn() }, 'Body'), container)
    const el = container.querySelector('[role="alertdialog"]')
    expect(el?.getAttribute('aria-modal')).toBe('true')
  })

  it('renders title', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'Alert Title', onClose: vi.fn() }, 'Body'), container)
    expect(container.textContent).toContain('Alert Title')
  })

  it('renders description', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', description: 'Desc', onClose: vi.fn() }, 'Body'), container)
    expect(container.textContent).toContain('Desc')
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', onClose: vi.fn() }, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('does not close on Escape when allowEsc=false', () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', onClose, allowEsc: false }, 'Body'), container)
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(onClose).not.toHaveBeenCalled()
  })

  it('closes on Escape when allowEsc=true', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(AlertDialog, { open: true, title: 'T', onClose, allowEsc: true }, 'Body'), container)
    await new Promise((r) => setTimeout(r, 10))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Escape'
    document.dispatchEvent(ev)
    expect(onClose).toHaveBeenCalledOnce()
  })
})
