// @vitest-environment happy-dom
//
// jest-axe coverage for CopyIdButton — icon-only button. Tests guard
// the accessible-name fallback chain (ariaLabel || `${label} 복사` ||
// '복사'); a regression that drops both label and ariaLabel would yield
// a button with only an SVG icon and no name (WCAG 4.1.2).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CopyIdButton } from './copy-id-button'

describe('CopyIdButton a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render uses fallback aria-label "복사"', async () => {
    render(html`<${CopyIdButton} value="abc-123" />`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-label')).toBe('복사')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with `label` derives "<label> 복사" aria-label', async () => {
    render(html`<${CopyIdButton} value="abc-123" label="Session ID" />`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-label')).toBe('Session ID 복사')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('explicit `ariaLabel` overrides the derived label', async () => {
    render(
      html`<${CopyIdButton} value="abc" label="Session ID" ariaLabel="Copy session id" />`,
      container,
    )
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-label')).toBe('Copy session id')
    expect(await axe(container)).toHaveNoViolations()
  })
})
