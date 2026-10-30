// @vitest-environment happy-dom
//
// First a11y test under the new jest-axe + vitest pipeline.
// Acts as a smoke test for the matcher wiring AND a baseline for ActionButton.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ActionButton } from './button'

describe('ActionButton a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('has no detectable axe violations in the default render', async () => {
    render(html`<${ActionButton}>Save<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('icon-only button passes when ariaLabel is supplied', async () => {
    render(html`<${ActionButton} ariaLabel="cancel task">×<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('disabled state renders accessibly', async () => {
    render(html`<${ActionButton} disabled=${true} ariaBusy=${true}>Saving...<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('toggle (aria-pressed) state renders accessibly', async () => {
    render(html`<${ActionButton} pressed=${true}>Filter<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})
