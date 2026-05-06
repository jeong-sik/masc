// @vitest-environment happy-dom
//
// jest-axe coverage for CopyableCode — single-line shell snippet with
// a copy button. The button is icon-only by default, so tests guard
// the accessible-name fallback chain (ariaLabel || `${label} 복사` ||
// '명령 복사' — same pattern as CopyIdButton).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CopyableCode } from './copyable-code'

describe('CopyableCode a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default (secondary) variant renders accessibly', async () => {
    render(html`<${CopyableCode} command="npm install" />`, container)
    const root = container.querySelector('[data-copyable-code]')!
    expect(root.getAttribute('data-copyable-state')).toBe('idle')
    expect(root.getAttribute('data-copyable-command-length')).toBe('11')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('primary variant renders accessibly', async () => {
    render(
      html`<${CopyableCode} command="masc deploy" variant="primary" />`,
      container,
    )
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copyable-variant')).toBe('primary')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with label derives accessible name on the copy button', async () => {
    render(
      html`<${CopyableCode} command="masc start" label="Start command" />`,
      container,
    )
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copyable-has-label')).toBe('true')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with explicit ariaLabel passes axe', async () => {
    render(
      html`<${CopyableCode}
        command="curl -sSL https://example.com/install.sh | sh"
        ariaLabel="Copy install command"
      />`,
      container,
    )
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copyable-has-explicit-aria-label')).toBe('true')
    expect(await axe(container)).toHaveNoViolations()
  })
})
