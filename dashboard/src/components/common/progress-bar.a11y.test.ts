// @vitest-environment happy-dom
//
// jest-axe coverage for ProgressBar — single-value progress indicator.
// axe primarily verifies: (1) progressbar role + aria-valuenow/min/max
// wiring is intact, and (2) the tone palette stays above WCAG AA
// contrast across all 8 tones.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ProgressBar } from './progress-bar'

describe('ProgressBar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render with pct passes axe', async () => {
    render(html`<${ProgressBar} pct=${42} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with ariaLabel passes axe', async () => {
    render(
      html`<${ProgressBar} pct=${75} ariaLabel="Build progress" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all 4 status tones (accent/ok/warn/bad) pass axe', async () => {
    render(
      html`<div>
        <${ProgressBar} pct=${30} tone="accent" ariaLabel="Accent" />
        <${ProgressBar} pct=${85} tone="ok" ariaLabel="Ok" />
        <${ProgressBar} pct=${60} tone="warn" ariaLabel="Warn" />
        <${ProgressBar} pct=${15} tone="bad" ariaLabel="Bad" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('extended tone palette (emerald/amber/rose/sky) passes axe', async () => {
    render(
      html`<div>
        <${ProgressBar} pct=${50} tone="emerald" ariaLabel="Emerald" />
        <${ProgressBar} pct=${50} tone="amber" ariaLabel="Amber" />
        <${ProgressBar} pct=${50} tone="rose" ariaLabel="Rose" />
        <${ProgressBar} pct=${50} tone="sky" ariaLabel="Sky" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('pct=0 and pct=100 boundary cases pass axe', async () => {
    render(
      html`<div>
        <${ProgressBar} pct=${0} ariaLabel="Empty" />
        <${ProgressBar} pct=${100} ariaLabel="Full" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
