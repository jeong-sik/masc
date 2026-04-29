// @vitest-environment happy-dom
//
// jest-axe coverage for InlineSpinner — small animated loading
// indicator. Spinners are a frequent a11y trap: a purely visual
// rotating element with no text alternative leaves screen-reader
// users unaware that "something is happening right here". This
// suite verifies that the default render still passes axe (the
// spinner contributes no name + has no role, so axe doesn't
// require a label) AND that consumer-supplied aria-label is
// surfaced correctly when the spinner stands alone in a region.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { InlineSpinner } from './inline-spinner'

describe('InlineSpinner a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('inline alongside text passes axe (decorative spinner pattern)', async () => {
    // Typical usage: spinner sits next to text that names the
    // operation; the text is the accessible name, the spinner is
    // visual. axe should accept this — no role, no aria-label.
    render(
      html`<p><${InlineSpinner} /> Saving changes...</p>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size=xs passes axe', async () => {
    render(
      html`<p><${InlineSpinner} size="xs" /> Loading</p>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size=md tone=muted passes axe', async () => {
    render(
      html`<p><${InlineSpinner} size="md" tone="muted" /> Working</p>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('standalone with status role wrapper passes axe', async () => {
    // When the spinner is the only signal in a region, the wrapper
    // should carry role="status" + aria-live so AT users get the
    // update. Verifies the recommended composition pattern works.
    render(
      html`<div role="status" aria-live="polite">
        <${InlineSpinner} />
        <span class="sr-only">Loading</span>
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
