// @vitest-environment happy-dom
//
// jest-axe coverage for HeartbeatStreakChip — tiny status badge
// answering "how long has this connector been in its current state?".
// axe guards: tone palette (up/down/unknown) maintains WCAG AA
// contrast; the chip's text content carries enough information for
// AT users (no color-only signal).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { HeartbeatStreakChip } from './heartbeat-streak-chip'
import type { HeartbeatState } from '../../lib/heartbeat-history'

const upHistory: HeartbeatState[] = Array<HeartbeatState>(22).fill('up')
const downHistory: HeartbeatState[] = Array<HeartbeatState>(3).fill('down')
const unknownHistory: HeartbeatState[] = Array<HeartbeatState>(1).fill('unknown')

describe('HeartbeatStreakChip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('up streak passes axe (operational tone)', async () => {
    render(
      html`<${HeartbeatStreakChip} history=${upHistory} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('down streak passes axe (failure tone)', async () => {
    render(
      html`<${HeartbeatStreakChip} history=${downHistory} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('unknown streak passes axe (muted tone)', async () => {
    render(
      html`<${HeartbeatStreakChip} history=${unknownHistory} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('empty history (no data) renders nothing accessibly', async () => {
    render(html`<${HeartbeatStreakChip} history=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
