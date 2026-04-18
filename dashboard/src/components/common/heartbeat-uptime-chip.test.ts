// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  HeartbeatUptimeChip,
  formatUptimeChip,
} from './heartbeat-uptime-chip'
import { summarizeHistory } from './heartbeat-strip'

describe('formatUptimeChip (pure)', () => {
  it('returns null when no observed samples (all unknown / empty)', () => {
    expect(formatUptimeChip(summarizeHistory([]))).toBeNull()
    expect(formatUptimeChip(summarizeHistory(['unknown', 'unknown']))).toBeNull()
  })

  it('100% → operational, label="100"', () => {
    const view = formatUptimeChip(summarizeHistory(['up', 'up', 'up']))
    expect(view).toEqual({ label: '100', tone: 'operational' })
  })

  it('>= 99% → operational with 2-decimal label (Uptime Kuma convention)', () => {
    // 199 up out of 200 observed = 99.5%
    const history = [...Array(199).fill('up'), 'down'] as const
    const view = formatUptimeChip(summarizeHistory(history as unknown as ReturnType<typeof summarizeHistory>['total'] extends number ? any : never))
    expect(view?.tone).toBe('operational')
    expect(view?.label).toBe('99.50')
  })

  it('95-99% → degraded (amber) with 1-decimal label', () => {
    // 4 up, 1 down = 80% — too low
    // 19 up, 1 down = 95% — right at threshold
    const hist = [...Array(19).fill('up'), 'down']
    const view = formatUptimeChip(summarizeHistory(hist as any))
    expect(view?.tone).toBe('degraded')
    expect(view?.label).toBe('95.0')
  })

  it('< 95% → unhealthy (rose)', () => {
    // 3 up, 1 down = 75%
    const view = formatUptimeChip(summarizeHistory(['up', 'up', 'up', 'down']))
    expect(view?.tone).toBe('unhealthy')
    expect(view?.label).toBe('75.0')
  })

  it('unknown samples do not drag the percentage down', () => {
    // 2 up, 0 down, 10 unknown = 100% of observed
    const view = formatUptimeChip(summarizeHistory([
      'unknown', 'unknown', 'up', 'up',
      'unknown', 'unknown', 'unknown', 'unknown',
      'unknown', 'unknown', 'unknown', 'unknown',
    ]))
    expect(view).toEqual({ label: '100', tone: 'operational' })
  })

  it('99.995% rounds up and renders as exact "100"', () => {
    // Avoid "99.99" appearing when fractional arithmetic produces
    // 99.99500001 style values — regression guard for floating noise.
    const view = formatUptimeChip({
      total: 10000, up: 9999, down: 0, unknown: 1, uptimePct: 100,
    })
    expect(view).toEqual({ label: '100', tone: 'operational' })
  })
})

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
    expect(el.className).toContain('var(--ok)')
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
    expect(el.className).toContain('var(--warn)')
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
