// @vitest-environment happy-dom
//
// jest-axe coverage for LivePulseDot, the dot that says whether the
// dashboard's observer stream is admitted. Both states keep an accessible
// name (title + aria-label) beyond colour.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { LivePulseDot } from './live-pulse-dot'
import { dashboardObserverPhase } from '../../dashboard-observer-state'

describe('LivePulseDot a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    dashboardObserverPhase.value = 'stopped'
  })

  it('live state passes axe', async () => {
    dashboardObserverPhase.value = 'live'
    render(html`<${LivePulseDot} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('refused state passes axe', async () => {
    dashboardObserverPhase.value = 'refused'
    render(html`<${LivePulseDot} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
