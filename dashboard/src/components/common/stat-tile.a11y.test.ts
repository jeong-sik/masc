// @vitest-environment happy-dom
//
// jest-axe coverage for StatGrid (StatTile is internal — exposed via the
// grid). Tests pin KPI status classes, grid columns config, and delta text.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { StatGrid } from './stat-tile'

describe('StatGrid a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default status grid passes axe', async () => {
    render(
      html`<${StatGrid}
        items=${[
          { label: 'Online', value: 12 },
          { label: 'Idle', value: 3 },
        ]}
        cols=${2}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all 4 statuses in one grid pass axe', async () => {
    render(
      html`<${StatGrid}
        items=${[
          { label: 'Critical', value: 1, status: 'crit' },
          { label: 'Warn', value: 2, status: 'warn' },
          { label: 'Ok', value: 3, status: 'ok' },
          { label: 'Neutral', value: 4, status: 'brass' },
        ]}
        cols=${4}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tiles with delta text pass axe', async () => {
    render(
      html`<${StatGrid}
        items=${[
          { label: 'Throughput', value: '1.2k', delta: { direction: 'flat', text: 'last 5m' } },
          { label: 'Errors', value: 0, status: 'ok', delta: { direction: 'flat', text: 'all clear' } },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('single-column dense grid passes axe', async () => {
    render(
      html`<${StatGrid}
        items=${[{ label: 'Total', value: 99 }]}
        cols=${1}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
