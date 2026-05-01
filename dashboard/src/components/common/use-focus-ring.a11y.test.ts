// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useFocusRing } from './use-focus-ring'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function Focusable() {
  const { focusRingProps, focused, focusVisible } = useFocusRing()
  return html`
    <button
      ...${focusRingProps}
      data-focused=${focused ? 'true' : undefined}
      data-focus-visible=${focusVisible ? 'true' : undefined}
    >
      Focus me
    </button>
  `
}

describe('useFocusRing', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('marks focused on focus', async () => {
    render(html`<${Focusable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.focus()
    await tick()
    expect(btn.getAttribute('data-focused')).toBe('true')
  })

  it('marks focus-visible when no relatedTarget (keyboard)', async () => {
    render(html`<${Focusable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: null, bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-focus-visible')).toBe('true')
  })

  it('marks focus-visible when relatedTarget has tabIndex -1', async () => {
    render(html`<${Focusable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    const related = document.createElement('div')
    related.setAttribute('tabindex', '-1')
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: related, bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-focus-visible')).toBe('true')
  })

  it('does not mark focus-visible when relatedTarget is tabbable (mouse)', async () => {
    render(html`<${Focusable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    const related = document.createElement('button')
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: related, bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-focus-visible')).toBeNull()
  })

  it('clears state on blur', async () => {
    render(html`<${Focusable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: null, bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-focused')).toBe('true')
    btn.dispatchEvent(new FocusEvent('blur', { bubbles: true }))
    await tick()
    expect(btn.getAttribute('data-focused')).toBeNull()
    expect(btn.getAttribute('data-focus-visible')).toBeNull()
  })

  it('renders accessibly', async () => {
    render(html`<${Focusable} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
