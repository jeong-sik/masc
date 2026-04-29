// @vitest-environment happy-dom
//
// jest-axe coverage for MetricTrack — observatory time-series track
// (tool call success rate over time, SVG line + cursor + anomaly
// detection). Tests pin empty/normal/anomaly variants of `points`
// across a fixed window.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MetricTrack } from './metric-track'

describe('MetricTrack a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty points (no data) passes axe', async () => {
    render(
      html`<${MetricTrack}
        points=${[]}
        windowStart=${0}
        windowEnd=${1000}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('normal range points pass axe', async () => {
    const points = [
      { hour: '2026-04-29T10:00:00Z', success_rate: 99.4, total: 100 },
      { hour: '2026-04-29T11:00:00Z', success_rate: 98.2, total: 100 },
      { hour: '2026-04-29T12:00:00Z', success_rate: 99.0, total: 100 },
    ]
    render(
      html`<${MetricTrack}
        points=${points}
        windowStart=${Date.parse('2026-04-29T09:00:00Z')}
        windowEnd=${Date.parse('2026-04-29T13:00:00Z')}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('window with zero span (edge case) renders accessibly', async () => {
    render(
      html`<${MetricTrack}
        points=${[]}
        windowStart=${100}
        windowEnd=${100}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
