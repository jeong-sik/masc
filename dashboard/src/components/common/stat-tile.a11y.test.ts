// @vitest-environment happy-dom
//
// jest-axe coverage for StatGrid (StatTile is internal — exposed via the
// grid). Tests pin all 4 variants (default/gold/accent/warn) + grid
// columns config + tiles with optional hint.
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

  it('default variant grid passes axe', async () => {
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

  it('all 4 variants in one grid pass axe', async () => {
    render(
      html`<${StatGrid}
        items=${[
          { label: 'Default', value: 10 },
          { label: 'Gold', value: 20, variant: 'gold' },
          { label: 'Accent', value: 30, variant: 'accent' },
          { label: 'Warn', value: 5, variant: 'warn' },
        ]}
        cols=${4}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('tiles with hint passes axe', async () => {
    render(
      html`<${StatGrid}
        items=${[
          { label: 'Throughput', value: '1.2k', hint: 'last 5m' },
          { label: 'Errors', value: 0, hint: 'all clear', variant: 'gold' },
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
