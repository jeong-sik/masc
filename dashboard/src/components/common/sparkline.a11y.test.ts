// @vitest-environment happy-dom
//
// jest-axe coverage for Sparkline. Canvas-based chart — accessible
// name comes from auto-generated aria-label OR caller override OR
// aria-hidden=true (when an adjacent numeric label already announces
// the value). Tests pin all three modes axe-clean.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Sparkline } from './sparkline'

describe('Sparkline a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default auto-aria-label passes axe', async () => {
    render(
      html`<${Sparkline} values=${[10, 12, 14, 13, 15, 18]} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('caller-supplied ariaLabel passes axe', async () => {
    render(
      html`<${Sparkline}
        values=${[1, 2, 3, 4, 5]}
        ariaLabel="Latency trend rising"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('decorative (ariaHidden=true) sparkline passes axe', async () => {
    render(
      html`<div>
        <span>42</span>
        <${Sparkline} values=${[40, 41, 42]} ariaHidden=${true} />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('insufficient data (< 2 points) renders accessibly', async () => {
    render(html`<${Sparkline} values=${[5]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
