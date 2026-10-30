// @vitest-environment happy-dom
//
// jest-axe coverage for SectionCap. Tiny uppercase tracking-wider
// section heading. Renders as <div> (not <h*>) by design — section
// caps are labels, not document outline. axe should still report 0
// violations across all tone/weight combinations.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { SectionCap } from './section-cap'

describe('SectionCap a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default (muted + normal) passes axe', async () => {
    render(html`<${SectionCap}>Recent activity<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tone=dim variant passes axe', async () => {
    render(
      html`<${SectionCap} tone="dim">Telemetry<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('weight=semibold variant passes axe', async () => {
    render(
      html`<${SectionCap} weight="semibold">Allowlist<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('caller-supplied extra class passes axe', async () => {
    render(
      html`<${SectionCap} class="mb-2 border-b border-[var(--color-border-divider)]">
        Diagnostics
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
