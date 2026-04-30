// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { InlineEdit } from './inline-edit'

describe('InlineEdit a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly in display mode', async () => {
    render(
      html`<${InlineEdit} value="hello" onSave=${vi.fn()} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty value', async () => {
    render(
      html`<${InlineEdit} value="" onSave=${vi.fn()} placeholder="type here" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with placeholder', async () => {
    render(
      html`<${InlineEdit} value="" onSave=${vi.fn()} placeholder="click to edit" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('switches to input and remains accessible', async () => {
    render(
      html`<${InlineEdit} value="editable" onSave=${vi.fn()} testId="ie" />`,
      container,
    )
    const span = container.querySelector('[data-testid="ie"]') as HTMLElement
    span.click()
    await new Promise(r => requestAnimationFrame(r))
    expect(await axe(container)).toHaveNoViolations()
  })

  it('calls onSave with new value on Enter', async () => {
    const onSave = vi.fn()
    render(
      html`<${InlineEdit} value="old" onSave=${onSave} testId="ie" />`,
      container,
    )
    const span = container.querySelector('[data-testid="ie"]') as HTMLElement
    span.click()
    await new Promise(r => requestAnimationFrame(r))
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'new'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    await new Promise(r => setTimeout(r, 0))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onSave).toHaveBeenCalledWith('new')
  })

  it('calls onCancel on Escape', async () => {
    const onCancel = vi.fn()
    render(
      html`<${InlineEdit} value="val" onSave=${vi.fn()} onCancel=${onCancel} testId="ie" />`,
      container,
    )
    const span = container.querySelector('[data-testid="ie"]') as HTMLElement
    span.click()
    await new Promise(r => requestAnimationFrame(r))
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'changed'
    input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    await new Promise(r => setTimeout(r, 0))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(onCancel).toHaveBeenCalled()
  })
})
