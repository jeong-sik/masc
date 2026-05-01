// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { LiveRegion } from './live-region'

describe('LiveRegion a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with polite messages', async () => {
    render(
      html`<${LiveRegion}
        messages=${[
          { id: 'm1', text: 'Agent started', priority: 'polite' },
          { id: 'm2', text: 'Task completed', priority: 'polite' },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with assertive messages', async () => {
    render(
      html`<${LiveRegion}
        messages=${[
          { id: 'm1', text: 'Error occurred', priority: 'assertive' },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with mixed priorities', async () => {
    render(
      html`<${LiveRegion}
        messages=${[
          { id: 'm1', text: 'Agent started', priority: 'polite' },
          { id: 'm2', text: 'Critical failure', priority: 'assertive' },
          { id: 'm3', text: 'Task completed', priority: 'polite' },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${LiveRegion} messages=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has sr-only class on container', () => {
    render(
      html`<${LiveRegion}
        messages=${[{ id: 'm1', text: 'Hello', priority: 'polite' }]}
      />`,
      container,
    )
    const region = container.querySelector('[data-live-region]')
    expect(region).not.toBeNull()
    expect(region?.classList.contains('sr-only')).toBe(true)
  })

  it('has aria-live polite region', () => {
    render(
      html`<${LiveRegion}
        messages=${[{ id: 'm1', text: 'Hello', priority: 'polite' }]}
      />`,
      container,
    )
    const polite = container.querySelector('[aria-live="polite"]')
    expect(polite).not.toBeNull()
  })

  it('has aria-live assertive region', () => {
    render(
      html`<${LiveRegion}
        messages=${[{ id: 'm1', text: 'Hello', priority: 'assertive' }]}
      />`,
      container,
    )
    const assertive = container.querySelector('[aria-live="assertive"]')
    expect(assertive).not.toBeNull()
  })
})
