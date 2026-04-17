// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { LivePulseDot, classifyLivePulse } from './live-pulse-dot'

const INTERVAL = 30_000
const NOW = 1_000_000_000_000

describe('classifyLivePulse (pure)', () => {
  it('null tick → idle (never sampled)', () => {
    const view = classifyLivePulse(null, NOW, INTERVAL)
    expect(view.state).toBe('idle')
    expect(view.label).toContain('대기')
  })

  it('tick within interval → live', () => {
    expect(classifyLivePulse(NOW - 5_000, NOW, INTERVAL).state).toBe('live')
  })

  it('tick just under 2× interval → still live (tolerates one miss)', () => {
    // 2× - 1ms = 59_999ms ago — Datadog "one missed heartbeat is fine".
    expect(classifyLivePulse(NOW - (INTERVAL * 2 - 1), NOW, INTERVAL).state).toBe('live')
  })

  it('tick past 2× interval → stale', () => {
    expect(classifyLivePulse(NOW - (INTERVAL * 2 + 1), NOW, INTERVAL).state).toBe('stale')
  })

  it('stale label includes seconds-ago for operator diagnostic', () => {
    const view = classifyLivePulse(NOW - 120_000, NOW, INTERVAL)
    expect(view.state).toBe('stale')
    expect(view.label).toContain('120s')
  })

  it('very recent tick (0 ms ago) is live', () => {
    expect(classifyLivePulse(NOW, NOW, INTERVAL).state).toBe('live')
  })
})

describe('LivePulseDot component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('idle state: grey dot, no pulse animation', () => {
    render(
      html`<${LivePulseDot} lastTickMs=${null} nowMs=${NOW} sampleIntervalMs=${INTERVAL} />`,
      container,
    )
    const el = container.querySelector('[data-live-pulse-dot]') as HTMLElement
    expect(el.getAttribute('data-live-pulse-state')).toBe('idle')
    expect(el.className).not.toContain('animate-pulse')
  })

  it('live state: emerald + animate-pulse (Datadog breathing dot)', () => {
    render(
      html`<${LivePulseDot} lastTickMs=${NOW - 1000} nowMs=${NOW} sampleIntervalMs=${INTERVAL} />`,
      container,
    )
    const el = container.querySelector('[data-live-pulse-dot]') as HTMLElement
    expect(el.getAttribute('data-live-pulse-state')).toBe('live')
    expect(el.className).toContain('emerald')
    expect(el.className).toContain('animate-pulse')
  })

  it('stale state: amber dot, no pulse (freeze signal stands still)', () => {
    render(
      html`<${LivePulseDot} lastTickMs=${NOW - 90_000} nowMs=${NOW} sampleIntervalMs=${INTERVAL} />`,
      container,
    )
    const el = container.querySelector('[data-live-pulse-dot]') as HTMLElement
    expect(el.getAttribute('data-live-pulse-state')).toBe('stale')
    expect(el.className).toContain('amber')
    // Regression guard: pulse animation MUST be off when stale — a
    // frozen sampler must not look identical to a live one.
    expect(el.className).not.toContain('animate-pulse')
  })

  it('title + aria-label carry the same narrative (hover + AT parity)', () => {
    render(
      html`<${LivePulseDot} lastTickMs=${NOW - 1000} nowMs=${NOW} sampleIntervalMs=${INTERVAL} />`,
      container,
    )
    const el = container.querySelector('[data-live-pulse-dot]')!
    expect(el.getAttribute('title')).toBe('Live polling · 샘플링 정상')
    expect(el.getAttribute('aria-label')).toBe('Live polling · 샘플링 정상')
  })

  it('role=img so screen readers announce the decorative shape semantically', () => {
    render(
      html`<${LivePulseDot} lastTickMs=${null} nowMs=${NOW} sampleIntervalMs=${INTERVAL} />`,
      container,
    )
    expect(container.querySelector('[data-live-pulse-dot]')!.getAttribute('role')).toBe('img')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${LivePulseDot}
        lastTickMs=${NOW}
        nowMs=${NOW}
        sampleIntervalMs=${INTERVAL}
        testId="overview-strip-live"
      />`,
      container,
    )
    expect(container.querySelector('[data-testid="overview-strip-live"]')).toBeTruthy()
  })
})
