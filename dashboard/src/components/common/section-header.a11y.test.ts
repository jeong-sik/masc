// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { SectionHeader } from './section-header'

describe('SectionHeader a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    // SectionHeader renders an <h4>; build a valid h1→h2→h3 chain
    // above so heading-order axe rule passes when the SectionHeader
    // appears in the test fragment.
    container = document.createElement('main')
    const h1 = document.createElement('h1'); h1.textContent = 'Page'
    const h2 = document.createElement('h2'); h2.textContent = 'Region'
    const h3 = document.createElement('h3'); h3.textContent = 'Group'
    container.append(h1, h2, h3)
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render passes axe', async () => {
    const slot = document.createElement('section')
    container.appendChild(slot)
    render(html`<${SectionHeader}>Recent activity<//>`, slot)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('with right slot (action) renders accessibly', async () => {
    const slot = document.createElement('section')
    container.appendChild(slot)
    render(
      html`<${SectionHeader} right=${html`<button type="button">View all</button>`}>Logs<//>`,
      slot,
    )
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})
