// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AlertDialog } from './alert-dialog'

describe('AlertDialog a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when open', async () => {
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        description="Something went wrong"
        onClose=${vi.fn()}
      >
        <button>OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role alertdialog', async () => {
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        onClose=${vi.fn()}
      >
        <button>OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    const dialog = container.querySelector('[role="alertdialog"]')
    expect(dialog).not.toBeNull()
  })

  it('has aria-modal true', async () => {
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        onClose=${vi.fn()}
      >
        <button>OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    const dialog = container.querySelector('[role="alertdialog"]')
    expect(dialog?.getAttribute('aria-modal')).toBe('true')
  })

  it('focuses first focusable element on open', async () => {
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        onClose=${vi.fn()}
      >
        <button id="first">OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(document.activeElement?.id).toBe('first')
  })

  it('does not close on Escape when allowEsc is false', async () => {
    const onClose = vi.fn()
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        onClose=${onClose}
        allowEsc=${false}
      >
        <button>OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(onClose).not.toHaveBeenCalled()
  })

  it('closes on Escape when allowEsc is true', async () => {
    const onClose = vi.fn()
    render(
      html`<${AlertDialog}
        open=${true}
        title="Error"
        onClose=${onClose}
        allowEsc=${true}
      >
        <button>OK</button>
      <//>`,
      container,
    )
    await new Promise((r) => setTimeout(r, 50))
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(onClose).toHaveBeenCalledOnce()
  })
})
