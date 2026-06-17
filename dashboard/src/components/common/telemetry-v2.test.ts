// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  TelemetryBars,
  Waterfall,
  FsmLifeline,
  TpsLive,
  SegmentedProgress,
  StreamingCaret,
} from './telemetry-v2'

describe('TelemetryBars', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders provided values as vertical bars', () => {
    render(
      html`<${TelemetryBars} values=${[{ h: 20 }, { h: 80, hot: true }]} />`,
      container,
    )
    const bars = container.querySelectorAll('.telemetry-bars__bar')
    expect(bars.length).toBe(2)
    expect(bars[0]?.getAttribute('style')).toContain('height: 20.00%')
    expect(bars[1]?.classList.contains('is-hot')).toBe(true)
  })

  it('clamps out-of-range heights', () => {
    render(
      html`<${TelemetryBars} values=${[{ h: -10 }, { h: 150 }]} />`,
      container,
    )
    const bars = container.querySelectorAll('.telemetry-bars__bar')
    expect(bars[0]?.getAttribute('style')).toContain('height: 0.00%')
    expect(bars[1]?.getAttribute('style')).toContain('height: 100.00%')
  })

  it('generates demo bars when values omitted', () => {
    render(html`<${TelemetryBars} count=${6} />`, container)
    expect(container.querySelectorAll('.telemetry-bars__bar').length).toBe(6)
  })

  it('passes testId through', () => {
    render(html`<${TelemetryBars} count=${2} testId="trace-bars" />`, container)
    expect(container.querySelector('[data-testid="trace-bars"]')).toBeTruthy()
  })

  it('exposes role=img for accessibility', () => {
    render(html`<${TelemetryBars} values=${[{ h: 50 }]} />`, container)
    expect(container.querySelector('.telemetry-bars')?.getAttribute('role')).toBe('img')
  })
})

describe('Waterfall', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const rows = [
    { kind: 'ctx' as const, label: 'context', left: 0, width: 20, dur: '120ms' },
    { kind: 'reason' as const, label: 'reason', mono: true, left: 25, width: 30, dur: '180ms' },
    { kind: 'tool' as const, label: 'tool_call', mono: true, left: 60, width: 25, dur: '90ms' },
    { kind: 'gen' as const, label: 'generate', left: 88, width: 12, dur: '40ms' },
  ]

  it('renders rows with correct kinds', () => {
    render(html`<${Waterfall} rows=${rows} total=${'430ms'} />`, container)
    expect(container.querySelectorAll('.waterfall__row').length).toBe(4)
    expect(container.querySelectorAll('.waterfall__bar--ctx').length).toBe(1)
    expect(container.querySelectorAll('.waterfall__bar--gen').length).toBe(1)
  })

  it('renders total footer', () => {
    render(html`<${Waterfall} rows=${rows} total=${'430ms'} />`, container)
    const foot = container.querySelector('.waterfall__foot')
    expect(foot?.textContent).toContain('total')
    expect(foot?.textContent).toContain('430ms')
  })

  it('positions bars by left/width percentages', () => {
    render(html`<${Waterfall} rows=${rows.slice(0, 1)} />`, container)
    const bar = container.querySelector('.waterfall__bar') as HTMLElement
    expect(bar.getAttribute('style')).toContain('left: 0.00%')
    expect(bar.getAttribute('style')).toContain('width: 20.00%')
  })

  it('applies mono class when requested', () => {
    render(html`<${Waterfall} rows=${rows.slice(1, 2)} />`, container)
    const name = container.querySelector('.waterfall__name')
    expect(name?.classList.contains('waterfall__name--mono')).toBe(true)
  })

  it('renders a legend', () => {
    render(html`<${Waterfall} rows=${[]} />`, container)
    const legend = container.querySelector('.waterfall__legend')
    expect(legend?.textContent).toContain('ctx')
    expect(legend?.textContent).toContain('reason')
    expect(legend?.textContent).toContain('tool')
    expect(legend?.textContent).toContain('gen')
  })
})

describe('FsmLifeline', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders steps with done/cur/pending states', () => {
    const steps = [
      { label: 'Boot', state: 'done' },
      { label: 'Load', state: 'done' },
      { label: 'Run', state: 'cur' },
      { label: 'Idle' },
    ]
    render(html`<${FsmLifeline} steps=${steps} />`, container)
    const stepEls = container.querySelectorAll('.fsm-lifeline-v2__step')
    expect(stepEls.length).toBe(4)
    expect(stepEls[0]?.classList.contains('fsm-lifeline-v2__step--done')).toBe(true)
    expect(stepEls[2]?.classList.contains('fsm-lifeline-v2__step--cur')).toBe(true)
  })

  it('exposes role=list and listitem', () => {
    render(html`<${FsmLifeline} steps=${[{ label: 'A' }]} />`, container)
    expect(container.querySelector('.fsm-lifeline-v2')?.getAttribute('role')).toBe('list')
    expect(container.querySelector('.fsm-lifeline-v2__step')?.getAttribute('role')).toBe('listitem')
  })
})

describe('TpsLive', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders rate and unit', () => {
    render(html`<${TpsLive} rate=${73} />`, container)
    expect(container.textContent).toContain('73 tok/s')
  })

  it('renders a live dot', () => {
    render(html`<${TpsLive} />`, container)
    expect(container.querySelector('.tps-live__dot')).toBeTruthy()
  })

  it('includes aria-label on value', () => {
    render(html`<${TpsLive} rate=${55} />`, container)
    const value = container.querySelector('.tps-live__value')
    expect(value?.getAttribute('aria-label')).toBe('55 tokens per second')
  })
})

describe('SegmentedProgress', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders segments in ratio', () => {
    render(html`<${SegmentedProgress} done=${50} wip=${30} blocked=${10} total=${100} />`, container)
    const segs = container.querySelectorAll('.segmented-progress__seg')
    expect(segs.length).toBe(4)
    expect(segs[0]?.getAttribute('style')).toContain('flex-grow: 50')
    expect(segs[0]?.classList.contains('segmented-progress__seg--done')).toBe(true)
    expect(segs[1]?.classList.contains('segmented-progress__seg--wip')).toBe(true)
    expect(segs[2]?.classList.contains('segmented-progress__seg--blocked')).toBe(true)
  })

  it('omits zero segments', () => {
    render(html`<${SegmentedProgress} done=${80} wip=${0} blocked=${0} />`, container)
    const segs = container.querySelectorAll('.segmented-progress__seg')
    expect(segs.length).toBe(1) // only done; rest is also 0 so omitted
  })

  it('uses provided total for ratio', () => {
    render(html`<${SegmentedProgress} done=${1} wip=${1} blocked=${1} total=${12} />`, container)
    const segs = container.querySelectorAll('.segmented-progress__seg')
    expect(segs[segs.length - 1]?.getAttribute('style')).toContain('flex-grow: 9')
  })
})

describe('StreamingCaret', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a caret span', () => {
    render(html`<${StreamingCaret} />`, container)
    expect(container.querySelector('.streaming-caret')).toBeTruthy()
  })

  it('is aria-hidden', () => {
    render(html`<${StreamingCaret} />`, container)
    const caret = container.querySelector('.streaming-caret')
    expect(caret?.getAttribute('aria-hidden')).toBe('true')
  })
})
