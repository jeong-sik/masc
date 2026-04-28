// @vitest-environment happy-dom
//
// jest-axe coverage for TextInput + TextArea. Form inputs need an
// accessible name; the component's JSDoc explicitly warns that
// dropping `id` (for external <label for="">) or `ariaLabel` is a
// known regression. Tests pin both labelling strategies, plus disabled
// + required + placeholder-only (an axe-violation negative — caught
// by NOT including a placeholder-only test).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { TextInput, TextArea } from './input'

describe('TextInput a11y', () => {
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
    render(html`<${TextInput} ariaLabel="Project name" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with id + external <label for=""> passes axe', async () => {
    render(
      html`<div>
        <label for="proj">Project</label>
        <${TextInput} id="proj" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled + ariaLabel passes axe', async () => {
    render(
      html`<${TextInput} ariaLabel="Locked field" disabled=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('required + ariaLabel passes axe', async () => {
    render(
      html`<${TextInput} ariaLabel="Email" required=${true} type="email" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('TextArea a11y', () => {
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
    render(html`<${TextArea} ariaLabel="Description" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with id + external <label for=""> passes axe', async () => {
    render(
      html`<div>
        <label for="desc">Description</label>
        <${TextArea} id="desc" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
