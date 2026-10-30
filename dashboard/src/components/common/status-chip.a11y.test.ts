// @vitest-environment happy-dom
//
// jest-axe coverage for StatusChip — pill renders status verdicts
// across the dashboard. Children content, tone palette, and uppercase
// toggle stay axe-clean (no aria-prohibited-attr from span chips and no
// contrast issues at the chip level).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { StatusChip } from './status-chip'

describe('StatusChip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('children API passes axe', async () => {
    render(html`<${StatusChip}>Active<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tone variants (semantic enum + raw Tailwind) pass axe', async () => {
    render(
      html`<div>
        <${StatusChip} tone="ok">OK<//>
        <${StatusChip} tone="warn">WARN<//>
        <${StatusChip} tone="err">ERR<//>
        <${StatusChip} tone="bg-[var(--accent-12)] text-white">custom<//>
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('uppercase=false (plain pill) passes axe', async () => {
    render(
      html`<${StatusChip} uppercase=${false}>file/path.ts<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
