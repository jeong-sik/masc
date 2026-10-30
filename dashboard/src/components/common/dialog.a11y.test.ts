// @vitest-environment happy-dom
//
// jest-axe coverage for DialogOverlay — the canonical modal primitive
// that ConfirmDialogOverlay and other future dialogs sit on top of.
// Strategic intent: lock the current focus-trap + aria-* wiring with
// axe so the upcoming useFocusScope migration (#11727) lands as
// zero-regression. axe verifies aria-modal + role="dialog" + the
// labelledBy / describedBy id wiring.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { DialogOverlay } from './dialog'

describe('DialogOverlay a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with title id wired via labelledBy passes axe', async () => {
    render(
      html`<${DialogOverlay}
        labelledBy="d1-title"
        onClose=${() => {}}
      >
        <h2 id="d1-title">Confirm action</h2>
        <p>Are you sure?</p>
        <button>OK</button>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with describedBy + body text passes axe', async () => {
    render(
      html`<${DialogOverlay}
        labelledBy="d2-title"
        describedBy="d2-desc"
        onClose=${() => {}}
      >
        <h2 id="d2-title">Delete</h2>
        <p id="d2-desc">This cannot be undone.</p>
        <button>Delete</button>
        <button>Cancel</button>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with custom panelClass + multiple actions passes axe', async () => {
    render(
      html`<${DialogOverlay}
        labelledBy="d3-title"
        onClose=${() => {}}
        panelClass="bg-[var(--color-bg-page)] rounded-[var(--r-1)] p-5"
      >
        <h2 id="d3-title">Multi-action</h2>
        <button>Primary</button>
        <button>Secondary</button>
        <button>Cancel</button>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
