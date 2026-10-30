// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  Sparkline,
  sparklineStats,
  sparklineAriaLabel,
} from './sparkline'

describe('sparklineStats (pure)', () => {
  it('returns null for < 2 values (too short to form a trend)', () => {
    expect(sparklineStats([])).toBeNull()
    expect(sparklineStats([42])).toBeNull()
  })

  it('computes first / latest / min / max / range / delta correctly', () => {
    const s = sparklineStats([10, 15, 8, 20, 12])
    expect(s).toEqual({
      first: 10,
      latest: 12,
      min: 8,
      max: 20,
      range: 12,
      delta: 2,
    })
  })

  it('handles a flat series (range=0, delta=0)', () => {
    const s = sparklineStats([5, 5, 5, 5])
    expect(s).toEqual({
      first: 5,
      latest: 5,
      min: 5,
      max: 5,
      range: 0,
      delta: 0,
    })
  })

  it('handles negative values and a downward trend', () => {
    const s = sparklineStats([-2, 0, -5, -8])
    expect(s?.first).toBe(-2)
    expect(s?.latest).toBe(-8)
    expect(s?.min).toBe(-8)
    expect(s?.max).toBe(0)
    expect(s?.delta).toBe(-6)
  })
})

describe('sparklineAriaLabel (pure)', () => {
  it('returns the insufficient-data label for < 2 values', () => {
    expect(sparklineAriaLabel([42])).toBe('Sparkline (insufficient data)')
    expect(sparklineAriaLabel([])).toBe('Sparkline (insufficient data)')
  })

  it('formats integers without decimal places', () => {
    const label = sparklineAriaLabel([10, 15, 20])
    expect(label).toBe('Sparkline: 10 → 20 (min 10, max 20)')
  })

  it('formats non-integer values with 2 decimal places', () => {
    const label = sparklineAriaLabel([1.2345, 2.5, 3.7])
    expect(label).toContain('1.23')
    expect(label).toContain('3.70')
  })

  it('mentions first → latest and min/max bounds (Grafana convention)', () => {
    // Regression guard: the Grafana stat-panel narrative is
    // "first → latest (min X, max Y)". Any reorder breaks AT contract.
    const label = sparklineAriaLabel([5, 10, 2, 8])
    expect(label).toMatch(/^Sparkline: 5 → 8/)
    expect(label).toContain('min 2')
    expect(label).toContain('max 10')
  })
})

describe('Sparkline component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('returns null (renders nothing) for < 2 values', () => {
    render(html`<${Sparkline} values=${[42]} />`, container)
    expect(container.querySelector('canvas')).toBeNull()
  })

  it('renders a <canvas> for 2+ values', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} />`, container)
    expect(container.querySelector('canvas')).toBeTruthy()
  })

  it('canvas has role="img" (AT treats it as an image, not a generic element)', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} />`, container)
    const c = container.querySelector('canvas')!
    expect(c.getAttribute('role')).toBe('img')
  })

  it('default aria-label narrates first → latest + bounds (no caller work)', () => {
    render(html`<${Sparkline} values=${[10, 20, 15]} />`, container)
    const label = container.querySelector('canvas')!.getAttribute('aria-label')
    expect(label).toBe('Sparkline: 10 → 15 (min 10, max 20)')
  })

  it('caller can override aria-label with a custom narrative', () => {
    render(
      html`<${Sparkline} values=${[1, 2, 3]} ariaLabel="Request rate over the last hour" />`,
      container,
    )
    expect(container.querySelector('canvas')!.getAttribute('aria-label')).toBe(
      'Request rate over the last hour',
    )
  })

  it('ariaHidden=true removes aria-label AND sets aria-hidden="true" (decorative-only)', () => {
    // Regression guard: callers with a numeric label next to the
    // sparkline don't want AT to double-read. aria-hidden must win
    // over auto-generated aria-label.
    render(html`<${Sparkline} values=${[1, 2, 3]} ariaHidden=${true} />`, container)
    const c = container.querySelector('canvas')!
    expect(c.getAttribute('aria-hidden')).toBe('true')
    expect(c.hasAttribute('aria-label')).toBe(false)
  })

  it('ariaHidden=false / undefined keeps aria-label and omits aria-hidden', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} />`, container)
    const c = container.querySelector('canvas')!
    expect(c.hasAttribute('aria-label')).toBe(true)
    expect(c.hasAttribute('aria-hidden')).toBe(false)
  })

  it('testId renders as data-testid (E2E stable hook)', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} testId="tok-per-sec" />`, container)
    expect(container.querySelector('canvas')!.getAttribute('data-testid')).toBe('tok-per-sec')
  })

  it('class prop is appended to the base "block" class', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} class="my-2" />`, container)
    const cn = container.querySelector('canvas')!.className
    expect(cn).toContain('block')
    expect(cn).toContain('my-2')
  })

  it('base class preserved when no `class` prop is passed', () => {
    render(html`<${Sparkline} values=${[1, 2, 3]} />`, container)
    expect(container.querySelector('canvas')!.className).toBe('block')
  })
})
