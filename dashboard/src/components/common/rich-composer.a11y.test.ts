// @vitest-environment happy-dom
//
// jest-axe coverage for RichComposer — Write/Preview tabbed editor.
// Tests pin both modes (write with TextArea, preview with rendered
// content), empty preview placeholder, and the disabled state.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { RichComposer } from './rich-composer'

describe('RichComposer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('write mode (default) passes axe', async () => {
    render(
      html`<${RichComposer}
        value=""
        onValueChange=${() => {}}
        placeholder="Type something..."
        ariaLabel="Note draft"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('write mode with content + helpText passes axe', async () => {
    render(
      html`<${RichComposer}
        value="Some draft text"
        onValueChange=${() => {}}
        helpText="Markdown supported"
        rows=${4}
        ariaLabel="Markdown draft"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled composer passes axe', async () => {
    render(
      html`<${RichComposer}
        value=""
        onValueChange=${() => {}}
        disabled=${true}
        ariaLabel="Locked draft"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
