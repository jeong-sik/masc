// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { HeartbeatUptimeChip } from './heartbeat-uptime-chip'

describe('HeartbeatUptimeChip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders nothing for empty history', () => {
    render(html`<${HeartbeatUptimeChip} history=${[]} />`, container)
    expect(container.querySelector('[data-heartbeat-uptime-chip]')).toBeNull()
  })

  it('renders nothing when history has only unknown samples', () => {
    // New connector that's never been observed up/down yet — chip stays
    // invisible so the tile is not polluted with a fake "0%".
    render(
      html`<${HeartbeatUptimeChip} history=${['unknown', 'unknown', 'unknown']} />`,
      container,
    )
    expect(container.querySelector('[data-heartbeat-uptime-chip]')).toBeNull()
  })

  it('renders percentage + operational tone for 100% history', () => {
    render(
      html`<${HeartbeatUptimeChip} history=${['up', 'up', 'up']} />`,
      container,
    )
    const el = container.querySelector('[data-heartbeat-uptime-chip]') as HTMLElement
    expect(el).toBeTruthy()
    expect(el.textContent).toContain('100%')
    expect(el.className).toContain('var(--color-status-ok)')
    expect(el.getAttribute('data-heartbeat-uptime-tone')).toBe('operational')
    expect(el.getAttribute('data-heartbeat-uptime-pct')).toBe('100')
  })

  it('tone class reflects degraded band (warn) for 95-99%', () => {
    const hist = [...Array(19).fill('up'), 'down']
    render(
      html`<${HeartbeatUptimeChip} history=${hist} />`,
      container,
    )
    const el = container.querySelector('[data-heartbeat-uptime-chip]')!
    expect(el.className).toContain('var(--color-status-warn)')
    expect(el.getAttribute('data-heartbeat-uptime-tone')).toBe('degraded')
  })

  it('tone class reflects unhealthy band (bad) for < 95%', () => {
    render(
      html`<${HeartbeatUptimeChip} history=${['up', 'up', 'up', 'down']} />`,
      container,
    )
    const el = container.querySelector('[data-heartbeat-uptime-chip]')!
    expect(el.className).toContain('var(--bad-light)')
    expect(el.getAttribute('data-heartbeat-uptime-tone')).toBe('unhealthy')
  })

  it('title + aria-label include observed-sample fraction (hover tooltip parity)', () => {
    render(
      html`<${HeartbeatUptimeChip} history=${['up', 'up', 'up', 'down']} />`,
      container,
    )
    const el = container.querySelector('[data-heartbeat-uptime-chip]')!
    expect(el.getAttribute('title')).toBe('75.0% uptime · 3/4 observed')
    expect(el.getAttribute('aria-label')).toBe('75.0% uptime · 3/4 observed')
  })

  it('uses tabular-nums so chips align when stacked in a row', () => {
    // Regression guard — 4 connector tiles side-by-side, a "100" vs
    // "95.0" width mismatch makes the row dance visually.
    render(
      html`<${HeartbeatUptimeChip} history=${['up']} />`,
      container,
    )
    expect(container.querySelector('[data-heartbeat-uptime-chip]')!.className)
      .toContain('tabular-nums')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${HeartbeatUptimeChip} history=${['up']} testId="discord-uptime" />`,
      container,
    )
    expect(container.querySelector('[data-testid="discord-uptime"]')).toBeTruthy()
  })
})
