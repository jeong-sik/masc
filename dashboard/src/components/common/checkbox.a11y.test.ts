// @vitest-environment happy-dom
//
// jest-axe coverage for Checkbox — form input atom. Critical because
// a checkbox without an accessible name is a WCAG 2.1 violation
// (4.1.2 Name, Role, Value), and the component's own JSDoc warns that
// dropping the `ariaLabel` / `id` props is a known regression source.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Checkbox } from './checkbox'

describe('Checkbox a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with ariaLabel passes axe (icon-style standalone)', async () => {
    render(html`<${Checkbox} ariaLabel="Subscribe to newsletter" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with id + external <label for=""> passes axe', async () => {
    render(
      html`<div>
        <label for="agree">Agree to terms</label>
        <${Checkbox} id="agree" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with ariaLabelledby pointing at sibling element passes axe', async () => {
    render(
      html`<div>
        <span id="opt-label">Notify me</span>
        <${Checkbox} ariaLabelledby="opt-label" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled + ariaLabel passes axe', async () => {
    render(
      html`<${Checkbox} ariaLabel="Locked option" disabled=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('checked + ariaLabel passes axe', async () => {
    render(
      html`<${Checkbox} ariaLabel="Active filter" checked=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
