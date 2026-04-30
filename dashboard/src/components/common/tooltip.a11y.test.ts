// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Tooltip } from './tooltip'

describe('Tooltip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when hidden', async () => {
    render(
      html`<${Tooltip} content="help text"><button>Hover me</button><//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when visible', async () => {
    render(
      html`<${Tooltip} content="help text" testId="tt"><button>Hover me</button><//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    expect(await axe(container)).toHaveNoViolations()
  })

  it('shows tooltip on mouseenter', async () => {
    render(
      html`<${Tooltip} content="help text" testId="tt"><button>Hover me</button><//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    expect(container.querySelector('[data-testid="tt"]')).not.toBeNull()
  })

  it('hides tooltip on mouseleave', async () => {
    render(
      html`<${Tooltip} content="help text" testId="tt"><button>Hover me</button><//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    btn.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
    await new Promise(r => setTimeout(r, 100))
    expect(container.querySelector('[data-testid="tt"]')).toBeNull()
  })

  it('shows tooltip on focus', async () => {
    render(
      html`<${Tooltip} content="help text" testId="tt"><button>Focus me</button><//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new FocusEvent('focus', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    expect(container.querySelector('[data-testid="tt"]')).not.toBeNull()
  })

  it('hides tooltip on Escape', async () => {
    render(
      html`<${Tooltip} content="help text" testId="tt"><button>Focus me</button><//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new FocusEvent('focus', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    btn.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await new Promise(r => setTimeout(r, 100))
    expect(container.querySelector('[data-testid="tt"]')).toBeNull()
  })

  it('preserves existing trigger handlers', async () => {
    const onEnter = vi.fn()
    const onLeave = vi.fn()
    render(
      html`<${Tooltip} content="help text" testId="tt">
        <button onMouseEnter=${onEnter} onMouseLeave=${onLeave}>Hover me</button>
      <//>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }))
    await new Promise(r => setTimeout(r, 200))
    expect(onEnter).toHaveBeenCalled()
    btn.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
    await new Promise(r => setTimeout(r, 100))
    expect(onLeave).toHaveBeenCalled()
  })
})
