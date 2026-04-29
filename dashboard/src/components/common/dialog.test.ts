// @vitest-environment happy-dom
//
// Behavior tests for DialogOverlay. Locks the user-observable contract
// independent of focus-trap implementation choice (inline vs.
// useFocusScope migration #11827). Each test exercises one
// observable: open render, ESC closes, click-outside closes, click-
// inside does NOT close, body scroll lock, focus restoration on
// unmount.
//
// These tests run on the current main DialogOverlay AND must still
// pass once #11827 lands (the migration is behavior-preserving by
// definition).
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { DialogOverlay } from './dialog'

const flushUi = (): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, 30))

describe('DialogOverlay behavior', () => {
  let container: HTMLElement
  let outsideButton: HTMLButtonElement

  beforeEach(() => {
    document.body.innerHTML = ''
    document.body.style.overflow = ''
    outsideButton = document.createElement('button')
    outsideButton.id = 'outside'
    outsideButton.textContent = 'outside'
    document.body.appendChild(outsideButton)

    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.innerHTML = ''
    document.body.style.overflow = ''
  })

  it('renders the panel with the supplied labelledBy / aria-modal wiring', () => {
    render(
      html`<${DialogOverlay}
        labelledBy="t1"
        onClose=${() => {}}
        panelClass="panel"
      >
        <h2 id="t1">Hello</h2>
      <//>`,
      container,
    )
    const panel = container.querySelector('[role="dialog"]')!
    expect(panel.getAttribute('aria-modal')).toBe('true')
    expect(panel.getAttribute('aria-labelledby')).toBe('t1')
    expect(panel.classList.contains('panel')).toBe(true)
  })

  it('Escape key invokes onClose', async () => {
    const onClose = vi.fn()
    render(
      html`<${DialogOverlay}
        labelledBy="t2"
        onClose=${onClose}
      >
        <h2 id="t2">Title</h2>
      <//>`,
      container,
    )
    await flushUi()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('click on the overlay (outside panel) invokes onClose', async () => {
    const onClose = vi.fn()
    render(
      html`<${DialogOverlay}
        labelledBy="t3"
        onClose=${onClose}
        overlayClass="overlay"
      >
        <h2 id="t3">Title</h2>
      <//>`,
      container,
    )
    await flushUi()
    const overlay = container.querySelector('.overlay') as HTMLElement
    overlay.click()
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('click inside the panel does NOT invoke onClose', async () => {
    const onClose = vi.fn()
    render(
      html`<${DialogOverlay}
        labelledBy="t4"
        onClose=${onClose}
        overlayClass="overlay"
        panelClass="panel"
      >
        <h2 id="t4">Title</h2>
        <button id="inside">Inside</button>
      <//>`,
      container,
    )
    await flushUi()
    const inside = container.querySelector('#inside') as HTMLButtonElement
    inside.click()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('locks body overflow on mount and restores on unmount', async () => {
    document.body.style.overflow = 'auto' // arbitrary prior value
    render(
      html`<${DialogOverlay}
        labelledBy="t5"
        onClose=${() => {}}
      >
        <h2 id="t5">Title</h2>
      <//>`,
      container,
    )
    await flushUi()
    expect(document.body.style.overflow).toBe('hidden')
    render(null, container)
    expect(document.body.style.overflow).toBe('auto')
  })

  it('initialFocusRef target is focused on mount', async () => {
    const focusRef = { current: null as HTMLElement | null }
    function Probe(): unknown {
      return html`<${DialogOverlay}
        labelledBy="t6"
        onClose=${() => {}}
        initialFocusRef=${focusRef}
      >
        <h2 id="t6">Title</h2>
        <button
          ref=${(el: HTMLButtonElement | null) => {
            focusRef.current = el
          }}
          id="primary"
        >Primary</button>
        <button id="secondary">Secondary</button>
      <//>`
    }
    render(html`<${Probe} />`, container)
    await flushUi()
    expect(document.activeElement?.id).toBe('primary')
  })

  it('focus does not stay on the outside button after mount (focus moves into panel)', async () => {
    outsideButton.focus()
    expect(document.activeElement?.id).toBe('outside')
    render(
      html`<${DialogOverlay}
        labelledBy="t7"
        onClose=${() => {}}
      >
        <h2 id="t7">Title</h2>
        <button id="inside">Inside</button>
      <//>`,
      container,
    )
    await flushUi()
    expect(document.activeElement?.id).not.toBe('outside')
  })
})
