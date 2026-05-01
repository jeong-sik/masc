import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { InlineEdit } from './inline-edit'

describe('InlineEdit', () => {
  it('renders value in display mode', () => {
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'hello', onSave: () => {} }), container)
    expect(container.textContent).toContain('hello')
  })

  it('renders placeholder when value empty', () => {
    const container = document.createElement('div')
    render(h(InlineEdit, { value: '', onSave: () => {}, placeholder: 'Edit me' }), container)
    expect(container.textContent).toContain('Edit me')
  })

  it('switches to input on click', async () => {
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'hello', onSave: () => {} }), container)
    const span = container.querySelector('[role="button"]') as HTMLElement
    span.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('input')).not.toBeNull()
  })

  it('calls onSave with draft on Enter', async () => {
    const onSave = vi.fn()
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'hello', onSave }), container)
    const span = container.querySelector('[role="button"]') as HTMLElement
    span.click()
    await new Promise((r) => setTimeout(r, 0))
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'world'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Enter'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onSave).toHaveBeenCalledWith('world')
  })

  it('calls onCancel on Escape', async () => {
    const onCancel = vi.fn()
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'hello', onSave: () => {}, onCancel }), container)
    const span = container.querySelector('[role="button"]') as HTMLElement
    span.click()
    await new Promise((r) => setTimeout(r, 0))
    const input = container.querySelector('input') as HTMLInputElement
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Escape'
    input.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onCancel).toHaveBeenCalledOnce()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'x', onSave: () => {}, testId: 'edit-1' }), container)
    expect(container.querySelector('[data-testid="edit-1"]')).not.toBeNull()
  })

  it('shows input testId when editing', async () => {
    const container = document.createElement('div')
    render(h(InlineEdit, { value: 'x', onSave: () => {}, testId: 'edit-1' }), container)
    const span = container.querySelector('[role="button"]') as HTMLElement
    span.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[data-testid="edit-1-input"]')).not.toBeNull()
  })
})
