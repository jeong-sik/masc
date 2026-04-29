// @vitest-environment happy-dom
//
// jest-axe coverage for TimeAgo. <time> element with datetime attribute
// for machine parsing + aria-label for AT-readable absolute timestamp +
// title for tooltip. All three modes (relative/absolute/both) must
// axe-clean and preserve the accessible name.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { TimeAgo } from './time-ago'

describe('TimeAgo a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('relative mode (default) passes axe', async () => {
    const ts = new Date(Date.now() - 60_000).toISOString()
    render(html`<${TimeAgo} timestamp=${ts} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('absolute mode passes axe', async () => {
    const ts = new Date('2026-01-15T10:30:00Z').toISOString()
    render(
      html`<${TimeAgo} timestamp=${ts} mode="absolute" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('both mode (relative · absolute) passes axe', async () => {
    const ts = new Date(Date.now() - 3600_000).toISOString()
    render(html`<${TimeAgo} timestamp=${ts} mode="both" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('numeric (unix ms) timestamp passes axe', async () => {
    const ts = Date.now() - 7200_000
    render(html`<${TimeAgo} timestamp=${ts} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
