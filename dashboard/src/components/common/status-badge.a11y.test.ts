// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { StatusBadge } from './status-badge'

describe('StatusBadge a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly for each canonical status', async () => {
    render(
      html`<div>
        <${StatusBadge} status="active" />
        <${StatusBadge} status="in_progress" />
        <${StatusBadge} status="error" />
        <${StatusBadge} status="offline" />
      </div>`,
      container,
    )
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('explicit label override renders accessibly', async () => {
    render(html`<${StatusBadge} status="active" label="Online now" />`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})
