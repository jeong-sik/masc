// @vitest-environment happy-dom
//
// jest-axe coverage for ConfirmDialogOverlay. Dialog patterns are the
// densest a11y surface in the dashboard: aria-modal, aria-labelledby
// on the panel, focus-trap, ESC handler. axe primarily verifies the
// labelling and role wiring; focus-trap behavior is left to the
// FocusScope unit tests (#11697).
//
// The component is signal-driven (requestConfirm sets a module-scope
// signal). Each test triggers requestConfirm, renders the overlay,
// runs axe, then clicks Cancel to reset the signal — otherwise state
// would leak across tests in the same suite.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import {
  ConfirmDialogOverlay,
  requestConfirm,
} from './confirm-dialog'

async function dismiss(container: HTMLElement, pendingPromise: Promise<boolean>): Promise<void> {
  const cancelBtn = container.querySelector<HTMLButtonElement>('button')
  cancelBtn?.click()
  // Settle the requestConfirm promise so the next test starts clean.
  await pendingPromise.catch(() => undefined)
  // Force a no-op render to flush the closed signal.
  render(null, container)
}

describe('ConfirmDialogOverlay a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('closed state renders nothing (trivially accessible)', async () => {
    render(html`<${ConfirmDialogOverlay} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('open warning dialog passes axe (default tone)', async () => {
    const pending = requestConfirm({
      title: 'Discard changes?',
      message: 'Unsaved edits will be lost.',
    })
    render(html`<${ConfirmDialogOverlay} />`, container)
    expect(await axe(container)).toHaveNoViolations()
    await dismiss(container, pending)
  })

  it('open danger dialog passes axe', async () => {
    const pending = requestConfirm({
      title: 'Delete project?',
      message: 'This action cannot be undone.',
      tone: 'danger',
      confirmText: 'Delete',
    })
    render(html`<${ConfirmDialogOverlay} />`, container)
    expect(await axe(container)).toHaveNoViolations()
    await dismiss(container, pending)
  })

  it('open info dialog passes axe', async () => {
    const pending = requestConfirm({
      title: 'Heads up',
      message: 'A new version is available.',
      tone: 'info',
    })
    render(html`<${ConfirmDialogOverlay} />`, container)
    expect(await axe(container)).toHaveNoViolations()
    await dismiss(container, pending)
  })
})
