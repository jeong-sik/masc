// @vitest-environment happy-dom
//
// jest-axe coverage for Kbd — semantic <kbd> keyboard-shortcut pill.
// The native <kbd> element conveys the right semantic to assistive
// tech ("user input via keyboard"); axe primarily guards that the
// surrounding context (parent label, sibling text) doesn't break
// landmark/heading rules.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Kbd } from './kbd'

describe('Kbd a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('single-key default md size passes axe', async () => {
    render(html`<p>Press <${Kbd}>?<//></p>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size=sm passes axe (dense inline hint)', async () => {
    render(
      html`<p>Press <${Kbd} size="sm">/<//> to focus search</p>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('chord (multiple kbd) passes axe', async () => {
    render(
      html`<p>Save: <${Kbd}>Ctrl<//> + <${Kbd}>S<//></p>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('inside a button label passes axe (icon-button shortcut hint)', async () => {
    render(
      html`<button type="button" aria-label="Open command palette">
        <${Kbd}>⌘K<//>
      </button>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
