// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { StatusDot } from './status-dot'

describe('StatusDot a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render passes axe (decorative dot, aria-hidden expected)', async () => {
    render(html`<${StatusDot} />`, container)
    expect(container.querySelector('[data-status-dot]')!.getAttribute('data-status-dot-mode')).toBe('decorative')
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('all four sizes render accessibly', async () => {
    render(
      html`<div>
        <${StatusDot} size="xs" />
        <${StatusDot} size="sm" />
        <${StatusDot} size="md" />
        <${StatusDot} size="lg" />
      </div>`,
      container,
    )
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('semantic mode passes axe with an accessible name', async () => {
    render(html`<${StatusDot} ariaLabel="job healthy" class="bg-[var(--ok-10)]" />`, container)
    const dot = container.querySelector('[data-status-dot]')!
    expect(dot.getAttribute('data-status-dot-mode')).toBe('semantic')
    expect(dot.getAttribute('data-status-dot-has-aria-label')).toBe('true')
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})
