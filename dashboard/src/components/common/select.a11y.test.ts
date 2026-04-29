// @vitest-environment happy-dom
//
// jest-axe coverage for Select — native <select> form input. The
// component's JSDoc warns that dropping `id` / `ariaLabel` is a
// known regression; this suite makes axe enforce the contract.
// Mirrors the checkbox/input batches.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Select } from './select'

const STRING_OPTIONS = ['Apple', 'Banana', 'Cherry']
const OBJECT_OPTIONS = [
  { value: 'a', label: 'Alpha' },
  { value: 'b', label: 'Beta' },
]

describe('Select a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with ariaLabel + string options passes axe', async () => {
    render(
      html`<${Select} options=${STRING_OPTIONS} ariaLabel="Fruit" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with id + external <label for=""> + object options passes axe', async () => {
    render(
      html`<div>
        <label for="grade">Grade</label>
        <${Select} id="grade" options=${OBJECT_OPTIONS} />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with placeholder + ariaLabel passes axe', async () => {
    render(
      html`<${Select}
        ariaLabel="Pick one"
        placeholder="Choose…"
        options=${STRING_OPTIONS}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled + ariaLabel passes axe', async () => {
    render(
      html`<${Select}
        ariaLabel="Locked field"
        options=${STRING_OPTIONS}
        disabled=${true}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with value preselected passes axe', async () => {
    render(
      html`<${Select}
        ariaLabel="Pre-filled"
        options=${OBJECT_OPTIONS}
        value="b"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
