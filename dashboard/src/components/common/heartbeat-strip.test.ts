// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  HeartbeatStrip,
  padHistory,
  summarizeHistory,
  formatHeartbeatLabel,
} from './heartbeat-strip'
import type { HeartbeatState } from '../../lib/heartbeat-history'

describe('padHistory (pure)', () => {
  it('left-pads with "unknown" when history is shorter than slots', () => {
    const out = padHistory(['up', 'down'], 5)
    expect(out).toEqual(['unknown', 'unknown', 'unknown', 'up', 'down'])
  })

  it('returns tail slice when history is longer than slots', () => {
    const out = padHistory(['up', 'down', 'up', 'down', 'up'], 3)
    expect(out).toEqual(['up', 'down', 'up'])
  })

  it('returns the array unchanged when length === slots', () => {
    const input: HeartbeatState[] = ['up', 'down']
    const out = padHistory(input, 2)
    expect(out).toEqual(['up', 'down'])
  })

  it('pads with slots worth of unknowns when history is empty', () => {
    const out = padHistory([], 4)
    expect(out).toEqual(['unknown', 'unknown', 'unknown', 'unknown'])
  })
})

describe('summarizeHistory (pure)', () => {
  it('counts ups / downs / unknowns', () => {
    const s = summarizeHistory(['up', 'down', 'up', 'unknown', 'up'])
    expect(s.total).toBe(5)
    expect(s.up).toBe(3)
    expect(s.down).toBe(1)
    expect(s.unknown).toBe(1)
  })

  it('uptimePct ignores unknowns (Uptime Kuma convention)', () => {
    // 3 up, 1 down, 1 unknown — uptime = 3 / (3+1) = 75%
    const s = summarizeHistory(['up', 'down', 'up', 'unknown', 'up'])
    expect(s.uptimePct).toBe(75)
  })

  it('uptimePct is null when there are no observed samples', () => {
    expect(summarizeHistory([]).uptimePct).toBeNull()
    expect(summarizeHistory(['unknown', 'unknown']).uptimePct).toBeNull()
  })

  it('100% uptime when all observed samples are "up"', () => {
    expect(summarizeHistory(['up', 'up', 'up']).uptimePct).toBe(100)
  })

  it('0% uptime when all observed samples are "down"', () => {
    expect(summarizeHistory(['down', 'down']).uptimePct).toBe(0)
  })
})

describe('formatHeartbeatLabel (pure)', () => {
  it('returns "no data yet" when uptimePct is null', () => {
    const label = formatHeartbeatLabel({
      total: 0, up: 0, down: 0, unknown: 0, uptimePct: null,
    })
    expect(label).toBe('Heartbeat: no data yet')
  })

  it('uses 2 decimal places at ≥99% uptime (Uptime Kuma precision bump)', () => {
    // Regression guard: high uptime needs more precision or it renders
    // as "100.0%" which hides the difference between 99.95% and 100%.
    const label = formatHeartbeatLabel({
      total: 100, up: 99, down: 1, unknown: 0, uptimePct: 99,
    })
    expect(label).toContain('99.00')
  })

  it('uses 1 decimal for sub-99% uptime', () => {
    const label = formatHeartbeatLabel({
      total: 10, up: 5, down: 5, unknown: 0, uptimePct: 50,
    })
    expect(label).toContain('50.0')
    expect(label).not.toContain('50.00')
  })

  it('includes up/total observed (Uptime Kuma narrative)', () => {
    const label = formatHeartbeatLabel({
      total: 5, up: 3, down: 1, unknown: 1, uptimePct: 75,
    })
    expect(label).toContain('3/4 observed')
  })
})

describe('HeartbeatStrip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders `slots` bars (default 45)', () => {
    render(html`<${HeartbeatStrip} history=${['up', 'down']} />`, container)
    const bars = container.querySelectorAll('[data-heartbeat-bar]')
    expect(bars.length).toBe(45)
  })

  it('respects a smaller `slots` prop', () => {
    render(html`<${HeartbeatStrip} history=${['up', 'down']} slots=${10} />`, container)
    expect(container.querySelectorAll('[data-heartbeat-bar]').length).toBe(10)
  })

  it('the last bar is the most recent sample (right=newest)', () => {
    render(
      html`<${HeartbeatStrip} history=${['up', 'down']} slots=${4} />`,
      container,
    )
    const bars = Array.from(container.querySelectorAll('[data-heartbeat-bar]'))
    const states = bars.map(b => b.getAttribute('data-heartbeat-bar'))
    // slots=4, history=2 → 2 unknown pads + 'up' + 'down'
    expect(states).toEqual(['unknown', 'unknown', 'up', 'down'])
  })

  it('role="img" and auto aria-label summarize uptime', () => {
    render(
      html`<${HeartbeatStrip} history=${['up', 'up', 'down']} slots=${3} />`,
      container,
    )
    const el = container.querySelector('[role="img"]')!
    const label = el.getAttribute('aria-label') ?? ''
    expect(label).toContain('Heartbeat:')
    expect(label).toContain('2/3')
  })

  it('custom ariaLabel overrides the auto-generated narrative', () => {
    render(
      html`<${HeartbeatStrip} history=${['up']} ariaLabel="Discord pulse" />`,
      container,
    )
    expect(container.querySelector('[role="img"]')!.getAttribute('aria-label')).toBe(
      'Discord pulse',
    )
  })

  it('title attr mirrors aria-label (hover tooltip = AT narrative)', () => {
    render(html`<${HeartbeatStrip} history=${['up', 'down']} />`, container)
    const el = container.querySelector('[role="img"]')!
    expect(el.getAttribute('title')).toBe(el.getAttribute('aria-label'))
  })

  it('data-heartbeat-uptime = "n/a" when no observed samples', () => {
    render(html`<${HeartbeatStrip} history=${[]} />`, container)
    expect(container.querySelector('[role="img"]')!.getAttribute('data-heartbeat-uptime')).toBe('n/a')
  })

  it('data-heartbeat-uptime is a numeric string when samples exist', () => {
    render(html`<${HeartbeatStrip} history=${['up', 'up', 'down']} />`, container)
    const val = container.querySelector('[role="img"]')!.getAttribute('data-heartbeat-uptime')
    expect(val).toMatch(/^\d+\.\d{2}$/)
  })

  it('testId renders as data-testid (E2E stable hook)', () => {
    render(html`<${HeartbeatStrip} history=${['up']} testId="discord-pulse" />`, container)
    expect(
      container.querySelector('[data-testid="discord-pulse"]'),
    ).toBeTruthy()
  })

  it('class prop is appended to the base layout class', () => {
    render(html`<${HeartbeatStrip} history=${['up']} class="ml-2" />`, container)
    const cn = container.querySelector('[role="img"]')!.className
    expect(cn).toContain('inline-flex')
    expect(cn).toContain('ml-2')
  })
})
