// @vitest-environment happy-dom
//
// jest-axe coverage for HeartbeatStrip — full history bar paired with
// the streak/uptime chips already covered (#11815). Each strip cell is
// up/down/unknown coded; tests guard that the strip surface carries
// enough semantic information for AT (label + per-cell title) and
// that the tone palette stays above contrast threshold.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { HeartbeatStrip } from './heartbeat-strip'
import type { HeartbeatState } from '../../lib/heartbeat-history'

const allUp: HeartbeatState[] = Array<HeartbeatState>(60).fill('up')
const mixed: HeartbeatState[] = [
  ...Array<HeartbeatState>(40).fill('up'),
  ...Array<HeartbeatState>(15).fill('down'),
  ...Array<HeartbeatState>(5).fill('unknown'),
]
const allDown: HeartbeatState[] = Array<HeartbeatState>(60).fill('down')

describe('HeartbeatStrip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('all-up steady state passes axe', async () => {
    render(html`<${HeartbeatStrip} history=${allUp} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('mixed history (up/down/unknown) passes axe', async () => {
    render(html`<${HeartbeatStrip} history=${mixed} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all-down state passes axe (failure tone sweep)', async () => {
    render(html`<${HeartbeatStrip} history=${allDown} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('empty history renders accessibly', async () => {
    render(html`<${HeartbeatStrip} history=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
