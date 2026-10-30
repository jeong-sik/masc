// @vitest-environment happy-dom
//
// jest-axe coverage for CollapsibleSection. The component delegates
// disclosure semantics to native <details>/<summary>, so axe primarily
// guards: (1) heading-text-not-empty in the summary slot, (2)
// content-inside-disclosure-region landmark/role conformance, and
// (3) badges (extra summary content) not breaking the summary's
// accessible name.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CollapsibleSection } from './collapsible'

describe('CollapsibleSection a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('closed by default with text title passes axe', async () => {
    render(
      html`<${CollapsibleSection} title="Advanced settings">
        <p>panel content</p>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('open state passes axe', async () => {
    render(
      html`<${CollapsibleSection} title="Advanced settings" open=${true}>
        <p>panel content</p>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with badge in the summary slot still has an accessible name', async () => {
    render(
      html`<${CollapsibleSection}
        title="Filters"
        badge=${html`<span aria-hidden="true">·5</span>`}
      >
        <p>filter content</p>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('mountWhenOpen=true closed state still passes axe (children not yet mounted)', async () => {
    render(
      html`<${CollapsibleSection}
        title="Lazy panel"
        mountWhenOpen=${true}
      >
        <p>expensive content</p>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
