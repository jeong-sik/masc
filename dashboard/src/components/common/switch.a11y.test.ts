// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Switch } from './switch'

describe('Switch a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when checked', async () => {
    render(
      html`<${Switch} checked=${true} onChange=${vi.fn()} label="Enable feature" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when unchecked', async () => {
    render(
      html`<${Switch} checked=${false} onChange=${vi.fn()} label="Enable feature" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with aria-label only', async () => {
    render(html`<${Switch} checked=${false} onChange=${vi.fn()} label="Toggle" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when disabled', async () => {
    render(
      html`<${Switch} checked=${true} onChange=${vi.fn()} label="Locked" disabled=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('toggles on click', async () => {
    const onChange = vi.fn()
    render(
      html`<${Switch} checked=${false} onChange=${onChange} testId="sw" />`,
      container,
    )
    const el = container.querySelector('[data-testid="sw"]') as HTMLElement
    el.click()
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('toggles on Space key', async () => {
    const onChange = vi.fn()
    render(
      html`<${Switch} checked=${false} onChange=${onChange} testId="sw" />`,
      container,
    )
    const el = container.querySelector('[data-testid="sw"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('does not toggle when disabled', async () => {
    const onChange = vi.fn()
    render(
      html`<${Switch} checked=${false} onChange=${onChange} disabled=${true} testId="sw" />`,
      container,
    )
    const el = container.querySelector('[data-testid="sw"]') as HTMLElement
    el.click()
    el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onChange).not.toHaveBeenCalled()
  })
})
