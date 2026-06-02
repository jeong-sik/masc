// @vitest-environment happy-dom
//
// jest-axe coverage for StatCell. Wrapper carries role="group" + a
// composite aria-label (label: value [(detail)]) so AT announces the
// stat as one unit instead of three orphaned spans. Tests pin label
// presence across tone/size/detail combinations.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { StatCell } from './stat-cell'

describe('StatCell a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('label + value (md, no detail) passes axe', async () => {
    render(
      html`<${StatCell} label="Uptime" value="99.4%" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('label + value + detail (md) passes axe', async () => {
    render(
      html`<${StatCell}
        label="Active keepers"
        value=${42}
        detail="3 idle"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size=lg with tone class passes axe', async () => {
    render(
      html`<${StatCell}
        label="Total turns"
        value="1.2k"
        size="lg"
        tone="text-[var(--ok-light)]"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('bg=white-3 variant passes axe', async () => {
    render(
      html`<${StatCell} label="Errors" value=${0} bg="white-3" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
