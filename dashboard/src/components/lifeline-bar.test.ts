// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Heartbeat, LifelineBar, heartbeatPoints } from './lifeline-bar'

describe('heartbeatPoints (pure)', () => {
  it('returns 61 points (segments 0..60 inclusive) as space-separated pairs', () => {
    const out = heartbeatPoints(0, 320, 32)
    expect(out.split(' ')).toHaveLength(61)
  })

  it('first x is 0, last x equals width (within rounding)', () => {
    const out = heartbeatPoints(0, 320, 32).split(' ')
    expect(out[0]!.startsWith('0.0,')).toBe(true)
    expect(out[60]!.startsWith('320.0,')).toBe(true)
  })

  it('is deterministic for the same (phase, width, height)', () => {
    expect(heartbeatPoints(0.42, 240, 14)).toBe(heartbeatPoints(0.42, 240, 14))
  })

  it('changes when phase advances', () => {
    expect(heartbeatPoints(0, 320, 32)).not.toBe(heartbeatPoints(0.5, 320, 32))
  })

  it('honors a custom width — last x equals that width', () => {
    const out = heartbeatPoints(0, 240, 14).split(' ')
    expect(out[60]!.startsWith('240.0,')).toBe(true)
  })

  it('all y values stay within [0, height] for height=32 (no out-of-bounds spike)', () => {
    const out = heartbeatPoints(0, 320, 32).split(' ')
    for (const pt of out) {
      const y = Number(pt.split(',')[1])
      // Spikes go up to ±0.4 * height around the midline (16). Allow a
      // small fudge for the sin component (1.5px amplitude).
      expect(y).toBeGreaterThan(0)
      expect(y).toBeLessThan(32)
    }
  })

  it('uses default width/height when omitted', () => {
    const out = heartbeatPoints(0)
    expect(out.split(' ')).toHaveLength(61)
    const last = out.split(' ')[60]!
    expect(last.startsWith('320.0,')).toBe(true)
  })
})

describe('Heartbeat component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders an aria-hidden <svg> with the polyline trace', () => {
    render(html`<${Heartbeat} />`, container)
    const svg = container.querySelector('svg')!
    expect(svg).toBeTruthy()
    expect(svg.getAttribute('aria-hidden')).toBe('true')
    const poly = svg.querySelector('polyline')!
    expect(poly).toBeTruthy()
    const pts = poly.getAttribute('points')!
    expect(pts.split(' ')).toHaveLength(61)
  })

  it('honors width and height by setting the svg style and viewBox', () => {
    render(html`<${Heartbeat} width=${240} height=${14} />`, container)
    const svg = container.querySelector('svg')!
    expect(svg.getAttribute('viewBox')).toBe('0 0 240 14')
    expect((svg as unknown as SVGSVGElement).style.width).toBe('240px')
    expect((svg as unknown as SVGSVGElement).style.height).toBe('14px')
  })

  it('renders the trailing pulse dot (circle + animate) by default', () => {
    render(html`<${Heartbeat} />`, container)
    const circle = container.querySelector('circle')
    const animate = container.querySelector('animate')
    expect(circle).toBeTruthy()
    expect(animate).toBeTruthy()
    expect(animate!.getAttribute('attributeName')).toBe('r')
  })

  it('omits the pulse dot when withoutPulseDot is true', () => {
    render(html`<${Heartbeat} withoutPulseDot=${true} />`, container)
    expect(container.querySelector('circle')).toBeNull()
    expect(container.querySelector('animate')).toBeNull()
  })

  it('uses a custom color on both the polyline stroke and the dot fill', () => {
    render(html`<${Heartbeat} color="#ff0000" />`, container)
    expect(container.querySelector('polyline')!.getAttribute('stroke')).toBe('#ff0000')
    expect(container.querySelector('circle')!.getAttribute('fill')).toBe('#ff0000')
  })

  it('phase change updates the trace points (re-render)', () => {
    render(html`<${Heartbeat} phase=${0} />`, container)
    const before = container.querySelector('polyline')!.getAttribute('points')
    render(html`<${Heartbeat} phase=${0.7} />`, container)
    const after = container.querySelector('polyline')!.getAttribute('points')
    expect(after).not.toBe(before)
  })
})

describe('LifelineBar component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the LIFELINE label by default', () => {
    render(html`<${LifelineBar} />`, container)
    expect(container.textContent).toContain('LIFELINE')
  })

  it('honors a custom label', () => {
    render(html`<${LifelineBar} label="FLEET" />`, container)
    expect(container.textContent).toContain('FLEET')
  })

  it('renders the BPM + window caption when bpm is given', () => {
    render(html`<${LifelineBar} bpm=${72} window="60s" />`, container)
    expect(container.textContent).toContain('72')
    expect(container.textContent).toContain('BPM')
    expect(container.textContent).toContain('60s')
  })

  it('omits the BPM caption when bpm is undefined', () => {
    render(html`<${LifelineBar} />`, container)
    // Caption with "BPM" appears only when bpm is provided
    expect(container.textContent).not.toContain('BPM')
  })

  it('emits role="img" with a composed aria-label when bpm given', () => {
    render(html`<${LifelineBar} bpm=${72} window="60s" />`, container)
    const root = container.querySelector('[role="img"]')!
    expect(root.getAttribute('aria-label')).toBe('LIFELINE heartbeat at 72 BPM, 60s window')
  })

  it('falls back to a window-only aria-label when bpm omitted', () => {
    render(html`<${LifelineBar} />`, container)
    const root = container.querySelector('[role="img"]')!
    expect(root.getAttribute('aria-label')).toBe('LIFELINE heartbeat, 60s window')
  })

  it('caller-supplied ariaLabel overrides composition', () => {
    render(
      html`<${LifelineBar} bpm=${72} ariaLabel="Custom announcement" />`,
      container,
    )
    const root = container.querySelector('[role="img"]')!
    expect(root.getAttribute('aria-label')).toBe('Custom announcement')
  })

  it('renders the inner Heartbeat svg', () => {
    render(html`<${LifelineBar} />`, container)
    expect(container.querySelector('svg polyline')).toBeTruthy()
  })
})
