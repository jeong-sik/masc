// @vitest-environment happy-dom
//
// jest-axe coverage for NumberInput. Form input — same accessible-name
// strategy as Input/Checkbox/Select. Component's JSDoc warns dropping
// id/ariaLabel is a known regression; axe enforces it.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { NumberInput } from './number-input'

describe('NumberInput a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with ariaLabel passes axe', async () => {
    render(html`<${NumberInput} ariaLabel="Quantity" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with id + external <label for=""> passes axe', async () => {
    render(
      html`<div>
        <label for="qty">Quantity</label>
        <${NumberInput} id="qty" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with min/max/step + ariaLabel passes axe', async () => {
    render(
      html`<${NumberInput}
        ariaLabel="Sample size"
        min=${1}
        max=${100}
        step=${1}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled + ariaLabel passes axe', async () => {
    render(
      html`<${NumberInput} ariaLabel="Locked" disabled=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('placeholder + ariaLabel passes axe', async () => {
    render(
      html`<${NumberInput} ariaLabel="Optional count" placeholder="0" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
