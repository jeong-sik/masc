// @vitest-environment happy-dom
//
// jest-axe coverage for LivePulseDot — pulsing dot indicating polling
// liveness. Tests pin all 3 states (live/stale/idle) and verify the
// component's accessible-name strategy (title + aria-label combine to
// give the dot a descriptive name beyond color-only signaling).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { LivePulseDot } from './live-pulse-dot'

describe('LivePulseDot a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('live state (recent tick) passes axe', async () => {
    const recentTick = new Date().toISOString()
    render(
      html`<${LivePulseDot} lastTickAt=${recentTick} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('stale state (older tick) passes axe', async () => {
    const oldTick = new Date(Date.now() - 60_000).toISOString()
    render(
      html`<${LivePulseDot} lastTickAt=${oldTick} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('idle state (null tick — never sampled) passes axe', async () => {
    render(html`<${LivePulseDot} lastTickAt=${null} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
