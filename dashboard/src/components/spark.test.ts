// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Spark, sparkClamp, sparkAriaLabel, type SparkProps } from './spark'

describe('sparkClamp (pure)', () => {
  it('returns the value when in range', () => {
    expect(sparkClamp(50)).toBe(50)
    expect(sparkClamp(0)).toBe(0)
    expect(sparkClamp(100)).toBe(100)
  })

  it('clamps below 0 to 0', () => {
    expect(sparkClamp(-5)).toBe(0)
  })

  it('clamps above 100 to 100', () => {
    expect(sparkClamp(150)).toBe(100)
  })

  it('coerces NaN to 0', () => {
    expect(sparkClamp(Number.NaN)).toBe(0)
  })
})

describe('sparkAriaLabel (pure)', () => {
  it('reports no-data for empty series', () => {
    expect(sparkAriaLabel([])).toBe('Spark (no data)')
  })

  it('reports count + min/max/latest for a real series', () => {
    expect(sparkAriaLabel([10, 20, 30])).toBe('Spark: 3 samples, min 10, max 30, latest 30')
  })

  it('formats decimals to 1 place', () => {
    expect(sparkAriaLabel([1.234, 9.5])).toBe('Spark: 2 samples, min 1.2, max 9.5, latest 9.5')
  })
})

describe('Spark', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: SparkProps): HTMLElement {
    render(html`<${Spark} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a span with role=img by default', () => {
    const el = mount({ values: [10, 50, 90] })
    expect(el.tagName).toBe('SPAN')
    expect(el.getAttribute('role')).toBe('img')
  })

  it('records kind on data-kind', () => {
    const el = mount({ values: [10, 20], kind: 'ok' })
    expect(el.getAttribute('data-kind')).toBe('ok')
  })

  it('defaults to kind=default when omitted', () => {
    const el = mount({ values: [10, 20] })
    expect(el.getAttribute('data-kind')).toBe('default')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ values: [10, 20], testId: 'budget-spark' })
    expect(el.getAttribute('data-testid')).toBe('budget-spark')
  })

  it('renders one <i> per value', () => {
    const el = mount({ values: [10, 20, 30, 40] })
    const bars = el.querySelectorAll('i')
    expect(bars.length).toBe(4)
  })

  it('renders zero bars for empty series', () => {
    const el = mount({ values: [] })
    expect(el.querySelectorAll('i').length).toBe(0)
  })

  // ── SPEC geometry ──

  it('renders 16px height container (SPEC spark geometry)', () => {
    const el = mount({ values: [10, 20] })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('height: 16px')
  })

  it('uses inline-flex with flex-end alignment + 1px gap', () => {
    const el = mount({ values: [10, 20] })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('display: inline-flex')
    expect(style).toContain('align-items: flex-end')
    expect(style).toContain('gap: 1px')
  })

  it('each bar is 2px wide with min-height 1px', () => {
    const el = mount({ values: [50] })
    const bar = el.querySelector('i') as HTMLElement
    const bs = bar.getAttribute('style') ?? ''
    expect(bs).toContain('width: 2px')
    expect(bs).toContain('min-height: 1px')
  })

  it('encodes value as percentage height (SPEC value→height rule)', () => {
    const el = mount({ values: [25, 75] })
    const bars = el.querySelectorAll('i')
    expect((bars[0] as HTMLElement).getAttribute('style')).toContain('height: 25%')
    // last bar is the now-bar — height still encoded by value
    expect((bars[1] as HTMLElement).getAttribute('style')).toContain('height: 75%')
  })

  // ── Last-bar accent (now signal) ──

  it('paints the last bar with accent + glow shadow by default', () => {
    const el = mount({ values: [50, 50, 50] })
    const bars = el.querySelectorAll('i')
    const last = (bars[2] as HTMLElement).getAttribute('style') ?? ''
    expect(last).toContain('var(--color-accent-fg)')
    expect(last).toContain('--color-accent-glow')
    expect(last).toContain('box-shadow')
  })

  it('drops the last-bar accent when noNowAccent=true', () => {
    const el = mount({ values: [50, 50, 50], noNowAccent: true })
    const bars = el.querySelectorAll('i')
    const last = (bars[2] as HTMLElement).getAttribute('style') ?? ''
    expect(last).not.toContain('var(--color-accent-fg)')
    expect(last).not.toContain('box-shadow')
  })

  // ── Kind tones ──

  it('uses ok status token for ok kind (non-last bars)', () => {
    const el = mount({ values: [50, 50], kind: 'ok' })
    const first = (el.querySelector('i') as HTMLElement).getAttribute('style') ?? ''
    expect(first).toContain('var(--color-status-ok)')
  })

  it('uses warn status token for warn kind', () => {
    const el = mount({ values: [50, 50], kind: 'warn' })
    const first = (el.querySelector('i') as HTMLElement).getAttribute('style') ?? ''
    expect(first).toContain('var(--color-status-warn)')
  })

  it('uses err status token for err kind', () => {
    const el = mount({ values: [50, 50], kind: 'err' })
    const first = (el.querySelector('i') as HTMLElement).getAttribute('style') ?? ''
    expect(first).toContain('var(--color-status-err)')
  })

  // ── Aria ──

  it('sets aria-label from series stats by default', () => {
    const el = mount({ values: [10, 20, 30] })
    expect(el.getAttribute('aria-label')).toBe('Spark: 3 samples, min 10, max 30, latest 30')
  })

  it('lets caller override aria-label', () => {
    const el = mount({ values: [10, 20], ariaLabel: 'token usage 7d' })
    expect(el.getAttribute('aria-label')).toBe('token usage 7d')
  })

  it('marks decorative + drops role when ariaHidden=true', () => {
    const el = mount({ values: [10, 20], ariaHidden: true })
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.getAttribute('role')).toBe(null)
    expect(el.getAttribute('aria-label')).toBe(null)
  })

  // ── Clamping ──

  it('clamps out-of-range values in the rendered height', () => {
    const el = mount({ values: [-50, 0, 50, 150] })
    const bars = el.querySelectorAll('i')
    expect((bars[0] as HTMLElement).getAttribute('style')).toContain('height: 0%')
    expect((bars[3] as HTMLElement).getAttribute('style')).toContain('height: 100%')
  })
})
