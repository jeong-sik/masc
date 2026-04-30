// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Popover } from './popover'

describe('Popover a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when closed', async () => {
    render(
      html`<${Popover} trigger=${html`<button>Open</button>`}>
        <div>Content</div>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when open', async () => {
    render(
      html`<${Popover}
        trigger=${html`<button>Open</button>`}
        testId="popover-panel"
        aria-label="Settings"
      >
        <div>Content</div>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(await axe(container)).toHaveNoViolations()
  })

  it('trigger has aria-haspopup dialog', () => {
    render(
      html`<${Popover} trigger=${html`<button>Open</button>`}>
        <div>Content</div>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.getAttribute('aria-haspopup')).toBe('dialog')
  })

  it('trigger toggles aria-expanded on click', async () => {
    render(
      html`<${Popover} trigger=${html`<button>Open</button>`}>
        <div>Content</div>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.getAttribute('aria-expanded')).toBe('false')
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('aria-expanded')).toBe('true')
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('aria-expanded')).toBe('false')
  })

  it('closes on Escape', async () => {
    render(
      html`<${Popover}
        trigger=${html`<button>Open</button>`}
        testId="popover-panel"
      >
        <div>Content</div>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[data-testid="popover-panel"]')).not.toBeNull()
    window.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 50))
    expect(container.querySelector('[data-testid="popover-panel"]')).toBeNull()
  })

  it('calls onClose when dismissed', async () => {
    const onClose = vi.fn()
    render(
      html`<${Popover}
        trigger=${html`<button>Open</button>`}
        onClose=${onClose}
      >
        <div>Content</div>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })
})
