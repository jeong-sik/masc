// @vitest-environment happy-dom
//
// jest-axe coverage for HeartbeatUptimeChip — rolling uptime % badge.
// Pairs with HeartbeatStreakChip; both share the operational/degraded/
// unhealthy tone palette so axe verifies all 3 tones independently.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { HeartbeatUptimeChip } from './heartbeat-uptime-chip'
import type { HeartbeatState } from '../../lib/heartbeat-history'

function history(up: number, down: number, unknown: number): HeartbeatState[] {
  return [
    ...Array<HeartbeatState>(up).fill('up'),
    ...Array<HeartbeatState>(down).fill('down'),
    ...Array<HeartbeatState>(unknown).fill('unknown'),
  ]
}

describe('HeartbeatUptimeChip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('operational (>=99%) passes axe', async () => {
    render(
      html`<${HeartbeatUptimeChip} history=${history(100, 0, 0)} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('degraded (95-99%) passes axe', async () => {
    render(
      html`<${HeartbeatUptimeChip} history=${history(96, 4, 0)} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('unhealthy (<95%) passes axe', async () => {
    render(
      html`<${HeartbeatUptimeChip} history=${history(80, 20, 0)} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all unknown (returns null) renders nothing accessibly', async () => {
    render(
      html`<${HeartbeatUptimeChip} history=${history(0, 0, 5)} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
