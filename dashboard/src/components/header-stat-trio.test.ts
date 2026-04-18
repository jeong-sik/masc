// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  headerConnectedTone,
  headerSuccessTone,
  headerStatToneClass,
  HeaderMiniStat,
} from './connector-status'

describe('headerConnectedTone (pure)', () => {
  it('ok when connected === total', () => {
    expect(headerConnectedTone(4, 4)).toBe('ok')
    expect(headerConnectedTone(1, 1)).toBe('ok')
  })

  it('partial when some but not all connected', () => {
    expect(headerConnectedTone(2, 4)).toBe('partial')
    expect(headerConnectedTone(3, 4)).toBe('partial')
  })

  it('bad when zero connected out of non-zero total', () => {
    expect(headerConnectedTone(0, 4)).toBe('bad')
  })

  it('default when total is 0 (nothing to measure — avoid false "bad")', () => {
    // Regression guard: empty dashboard shouldn't render a red "0/0"
    // stat and alarm operators — that's a bootstrapping state, not a
    // failure.
    expect(headerConnectedTone(0, 0)).toBe('default')
    expect(headerConnectedTone(5, 0)).toBe('default')
  })

  it('ok when connected > total (safety against drift / stale counts)', () => {
    // If upstream count drifts and reports more connected than expected,
    // still treat as OK rather than some impossible "partial".
    expect(headerConnectedTone(5, 4)).toBe('ok')
  })
})

describe('headerSuccessTone (pure)', () => {
  it('ok when >= 95 (Grafana default "healthy" threshold)', () => {
    expect(headerSuccessTone(95)).toBe('ok')
    expect(headerSuccessTone(99.9)).toBe('ok')
    expect(headerSuccessTone(100)).toBe('ok')
  })

  it('partial for 70..<95 (degraded but serving)', () => {
    expect(headerSuccessTone(70)).toBe('partial')
    expect(headerSuccessTone(94.99)).toBe('partial')
  })

  it('bad below 70 (Grafana default "unhealthy" threshold)', () => {
    expect(headerSuccessTone(0)).toBe('bad')
    expect(headerSuccessTone(69.9)).toBe('bad')
  })

  it('default when success is null / undefined / NaN (no signal)', () => {
    expect(headerSuccessTone(null)).toBe('default')
    expect(headerSuccessTone(undefined)).toBe('default')
    expect(headerSuccessTone(Number.NaN)).toBe('default')
  })
})

describe('headerStatToneClass (pure)', () => {
  it('maps each tone to a distinct text-color utility', () => {
    expect(headerStatToneClass('ok')).toContain('var(--ok)')
    expect(headerStatToneClass('partial')).toContain('var(--warn)')
    expect(headerStatToneClass('bad')).toContain('var(--bad-light)')
    expect(headerStatToneClass('default')).toContain('text-')
  })

  it('returns a non-empty string for every tone (no "transparent" bug)', () => {
    for (const t of ['ok', 'partial', 'bad', 'default'] as const) {
      expect(headerStatToneClass(t).length).toBeGreaterThan(0)
    }
  })
})

describe('HeaderMiniStat component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders label and value', () => {
    render(html`<${HeaderMiniStat} label="connected" value="3/4" />`, container)
    const el = container.querySelector('[data-header-mini-stat="connected"]') as HTMLElement
    expect(el).toBeTruthy()
    expect(el.textContent).toContain('3/4')
    expect(el.textContent).toContain('connected')
  })

  it('tone attribute reflects the prop (E2E hook)', () => {
    render(html`<${HeaderMiniStat} label="success" value="87%" tone="partial" />`, container)
    const el = container.querySelector('[data-header-mini-stat="success"]')!
    expect(el.getAttribute('data-header-mini-stat-tone')).toBe('partial')
  })

  it('default tone when prop is omitted', () => {
    render(html`<${HeaderMiniStat} label="x" value="1" />`, container)
    const el = container.querySelector('[data-header-mini-stat="x"]')!
    expect(el.getAttribute('data-header-mini-stat-tone')).toBe('default')
  })

  it('value carries the tone text-color class (bad → var(--bad-light))', () => {
    render(html`<${HeaderMiniStat} label="x" value="0/4" tone="bad" />`, container)
    const el = container.querySelector('[data-header-mini-stat="x"]')!
    // Value is the first <span> child.
    const valueSpan = el.querySelector('span')!
    expect(valueSpan.className).toContain('var(--bad-light)')
  })

  it('testId renders as data-testid', () => {
    render(html`<${HeaderMiniStat} label="x" value="1" testId="header-stat-x" />`, container)
    expect(container.querySelector('[data-testid="header-stat-x"]')).toBeTruthy()
  })

  it('value uses tabular-nums so digits align across stats', () => {
    // Regression guard: "N/M" alignment across three side-by-side
    // stats breaks without tabular-nums — the "4" in different stat
    // widths slides around visually.
    render(html`<${HeaderMiniStat} label="x" value="42" />`, container)
    const valueSpan = container.querySelector('[data-header-mini-stat="x"] span')!
    expect(valueSpan.className).toContain('tabular-nums')
  })
})
