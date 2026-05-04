// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { DashedNotice } from './dashed-notice'

describe('DashedNotice component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a div with data-dashed-notice + attribute annotations', () => {
    render(html`<${DashedNotice}>still empty<//>`, container)
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('data-dashed-notice-size')).toBe('sm')
    expect(el.getAttribute('data-dashed-notice-border')).toBe('card')
    expect(el.textContent).toBe('still empty')
  })

  it('size + borderTone reflect in data attributes', () => {
    render(
      html`<${DashedNotice} size="md" borderTone="subtle">big empty<//>`,
      container,
    )
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.getAttribute('data-dashed-notice-size')).toBe('md')
    expect(el.getAttribute('data-dashed-notice-border')).toBe('subtle')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${DashedNotice} testId="runs-empty">no runs<//>`,
      container,
    )
    expect(container.querySelector('[data-testid="runs-empty"]')).toBeTruthy()
  })

  it('accepts arbitrary preact children (markup, not just strings)', () => {
    render(
      html`<${DashedNotice}>
        <strong>heads up</strong> — nothing yet
      <//>`,
      container,
    )
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.querySelector('strong')?.textContent).toBe('heads up')
  })
})
