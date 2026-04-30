// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ResizablePanel } from './resizable-panel'

describe('ResizablePanel a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`<${ResizablePanel}
        storageKey="test-a11y"
        first=${html`<div>left</div>`}
        second=${html`<div>right</div>`}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('separator has correct ARIA attributes', () => {
    render(
      html`<${ResizablePanel}
        storageKey="test-aria"
        direction="horizontal"
        defaultRatio=${0.4}
        first=${html`<div>left</div>`}
        second=${html`<div>right</div>`}
      />`,
      container,
    )
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    expect(sep).not.toBeNull()
    expect(sep.getAttribute('aria-orientation')).toBe('horizontal')
    expect(sep.getAttribute('aria-valuenow')).toBe('40')
    expect(sep.getAttribute('aria-valuemin')).toBe('5')
    expect(sep.getAttribute('aria-valuemax')).toBe('95')
    expect(sep.getAttribute('tabindex')).toBe('0')
  })

  it('updates aria-valuenow after keyboard resize', async () => {
    render(
      html`<${ResizablePanel}
        storageKey="test-kbd"
        direction="horizontal"
        defaultRatio=${0.5}
        first=${html`<div>left</div>`}
        second=${html`<div>right</div>`}
      />`,
      container,
    )
    const sep = container.querySelector('[role="separator"]') as HTMLElement
    sep.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    const next = parseInt(sep.getAttribute('aria-valuenow') || '0', 10)
    expect(next).toBeGreaterThan(50)
  })
})
