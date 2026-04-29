// @vitest-environment happy-dom
//
// jest-axe coverage for StatusChip — pill renders status verdicts
// across the dashboard. Two API surfaces (legacy `label` prop + modern
// `children`) plus tone palette + uppercase toggle. Tests guard that
// every combination remains axe-clean (no aria-prohibited-attr from
// span chips and no contrast issues at the chip level).
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

  it('legacy label prop passes axe', async () => {
    render(html`<${StatusChip} label="OK" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('children API passes axe', async () => {
    render(html`<${StatusChip}>Active</${StatusChip}>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tone variants (semantic enum + raw Tailwind) pass axe', async () => {
    render(
      html`<div>
        <${StatusChip} label="OK" tone="ok" />
        <${StatusChip} label="WARN" tone="warn" />
        <${StatusChip} label="ERR" tone="err" />
        <${StatusChip} label="custom" tone="bg-[var(--accent-12)] text-white" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('uppercase=false (plain pill) passes axe', async () => {
    render(
      html`<${StatusChip} uppercase=${false}>file/path.ts</${StatusChip}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
