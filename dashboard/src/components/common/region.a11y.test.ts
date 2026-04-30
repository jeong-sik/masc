// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Region } from './region'

describe('Region a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(html`<${Region} aria-label="Details">Content<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('is a section with aria-label', () => {
    render(html`<${Region} aria-label="Details">Content<//>`, container)
    const region = container.querySelector('section')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-label')).toBe('Details')
  })

  it('renders children', () => {
    render(html`<${Region} aria-label="X"><span>Child<//><//>`, container)
    expect(container.textContent).toContain('Child')
  })
})
