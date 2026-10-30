// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ProgressBar,
  progressBarWidthStyle,
  progressBarHeightClass,
  progressBarToneClass,
  progressBarTrackToneClass,
  summarizeProgressBar,
} from './progress-bar'

describe('progressBarWidthStyle (pure)', () => {
  it('mid-range % renders with 2-decimal precision', () => {
    expect(progressBarWidthStyle(42.5)).toBe('width: 42.50%')
  })

  it('clamps negatives to 0 (no CSS freakouts on bad input)', () => {
    expect(progressBarWidthStyle(-1)).toBe('width: 0.00%')
    expect(progressBarWidthStyle(-99)).toBe('width: 0.00%')
  })

  it('clamps > 100 to 100 (fill never overflows track)', () => {
    expect(progressBarWidthStyle(150)).toBe('width: 100.00%')
  })

  it('integer edge cases render cleanly', () => {
    expect(progressBarWidthStyle(0)).toBe('width: 0.00%')
    expect(progressBarWidthStyle(100)).toBe('width: 100.00%')
  })
})

describe('progressBarHeightClass (pure)', () => {
  it('default is sm (6px — baseline row bar)', () => {
    expect(progressBarHeightClass()).toBe('h-1.5')
  })

  it('each size maps to its expected Tailwind token', () => {
    expect(progressBarHeightClass('xs')).toBe('h-1')
    expect(progressBarHeightClass('sm')).toBe('h-1.5')
    expect(progressBarHeightClass('md')).toBe('h-2')
  })
})

describe('progressBarTrackToneClass (pure)', () => {
  it('default is the white-5 muted track', () => {
    expect(progressBarTrackToneClass()).toBe('bg-[var(--color-bg-elevated)]')
    expect(progressBarTrackToneClass('default')).toBe('bg-[var(--color-bg-elevated)]')
  })

  it('each variant maps to a distinct CSS var (no drift)', () => {
    expect(progressBarTrackToneClass('dim')).toBe('bg-[var(--color-bg-hover)]')
    expect(progressBarTrackToneClass('muted')).toBe('bg-[var(--color-bg-hover)]')
  })
})

describe('progressBarToneClass (pure)', () => {
  it('semantic tokens route to the dashboard CSS vars', () => {
    expect(progressBarToneClass('accent')).toBe('bg-[var(--color-accent-fg)]')
    expect(progressBarToneClass('ok')).toBe('bg-[var(--color-status-ok)]')
    expect(progressBarToneClass('warn')).toBe('bg-[var(--color-status-warn)]')
    expect(progressBarToneClass('bad')).toBe('bg-[var(--color-status-err)]')
  })

  it('raw Tailwind tones route to their bg-500 class', () => {
    expect(progressBarToneClass('emerald')).toBe('bg-[var(--ok-10)]')
    expect(progressBarToneClass('rose')).toBe('bg-[var(--bad-10)]')
  })
})

describe('summarizeProgressBar (pure)', () => {
  it('summarizes default progress bar state', () => {
    expect(summarizeProgressBar({ pct: 42.5 })).toEqual({
      inputPct: 42.5,
      clampedPct: 42.5,
      roundedPct: 43,
      widthStyle: 'width: 42.50%',
      size: 'sm',
      tone: 'accent',
      trackTone: 'default',
      isSemantic: false,
      fillSource: 'tone',
      hasCustomFillClass: false,
      fillClassLength: 0,
      hasTrackClass: false,
      trackClassLength: 0,
      hasTitle: false,
      titleLength: 0,
      hasTestId: false,
      testIdLength: 0,
    })
  })

  it('summarizes custom fill, semantic, and clamped state', () => {
    expect(summarizeProgressBar({
      pct: -9,
      size: 'md',
      tone: 'bad',
      class: 'bg-[var(--bad-10)]',
      trackTone: 'dim',
      trackClass: 'flex-1',
      title: '0% complete',
      ariaLabel: 'Build progress',
      testId: 'build-progress',
    })).toEqual({
      inputPct: -9,
      clampedPct: 0,
      roundedPct: 0,
      widthStyle: 'width: 0.00%',
      size: 'md',
      tone: 'bad',
      trackTone: 'dim',
      isSemantic: true,
      fillSource: 'custom-class',
      hasCustomFillClass: true,
      fillClassLength: 18,
      hasTrackClass: true,
      trackClassLength: 6,
      hasTitle: true,
      titleLength: 11,
      hasTestId: true,
      testIdLength: 14,
    })
  })
})

describe('ProgressBar component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders track + fill; fill width reflects clamped %', () => {
    render(html`<${ProgressBar} pct=${42.5} />`, container)
    const track = container.querySelector('[data-progress-bar]') as HTMLElement
    expect(track).toBeTruthy()
    expect(track.getAttribute('data-progress-bar-tone')).toBe('accent')
    expect(track.getAttribute('data-progress-bar-track-tone')).toBe('default')
    expect(track.getAttribute('data-progress-bar-input-pct')).toBe('42.5')
    expect(track.getAttribute('data-progress-bar-clamped-pct')).toBe('42.50')
    expect(track.getAttribute('data-progress-bar-is-semantic')).toBe('false')
    expect(track.getAttribute('data-progress-bar-fill-source')).toBe('tone')
    const fill = track.querySelector('div') as HTMLElement
    expect(fill.getAttribute('style')).toContain('width: 42.50%')
  })

  it('data-progress-bar-pct is integer-rounded-[var(--r-1)] for clean E2E selectors', () => {
    render(html`<${ProgressBar} pct=${33.7} />`, container)
    expect(container.querySelector('[data-progress-bar]')!.getAttribute('data-progress-bar-pct')).toBe('34')
  })

  it('decorative default: aria-hidden=true + no role=progressbar', () => {
    // Regression guard: many bars sit right next to a \"X%\" text label,
    // announcing role=progressbar + the same % would be duplicative.
    render(html`<${ProgressBar} pct=${50} />`, container)
    const track = container.querySelector('[data-progress-bar]') as HTMLElement
    expect(track.getAttribute('aria-hidden')).toBe('true')
    expect(track.getAttribute('role')).toBeNull()
  })

  it('ariaLabel promotes to semantic: role=progressbar + aria-valuenow/min/max', () => {
    render(
      html`<${ProgressBar} pct=${67.3} ariaLabel="Build progress" />`,
      container,
    )
    const track = container.querySelector('[data-progress-bar]') as HTMLElement
    expect(track.getAttribute('role')).toBe('progressbar')
    expect(track.getAttribute('aria-label')).toBe('Build progress')
    expect(track.getAttribute('aria-valuenow')).toBe('67')
    expect(track.getAttribute('aria-valuemin')).toBe('0')
    expect(track.getAttribute('aria-valuemax')).toBe('100')
    expect(track.getAttribute('aria-hidden')).toBeNull()
    expect(track.getAttribute('data-progress-bar-is-semantic')).toBe('true')
  })

  it('tone prop maps to the fill bg class', () => {
    render(html`<${ProgressBar} pct=${50} tone="ok" />`, container)
    const fill = container.querySelector('[data-progress-bar] > div') as HTMLElement
    expect(fill.className).toContain('bg-[var(--color-status-ok)]')
  })

  it('class prop overrides tone (threshold-varying colors)', () => {
    render(
      html`<${ProgressBar} pct=${50} class="bg-[var(--sky-400)]" />`,
      container,
    )
    const fill = container.querySelector('[data-progress-bar] > div') as HTMLElement
    expect(fill.className).toContain('bg-[var(--sky-400)]')
    // Tone fallback must NOT also be present when class is given.
    expect(fill.className).not.toContain('bg-[var(--color-accent-fg)]')
    const track = container.querySelector('[data-progress-bar]')!
    expect(track.getAttribute('data-progress-bar-fill-source')).toBe('custom-class')
    expect(track.getAttribute('data-progress-bar-has-custom-fill-class')).toBe('true')
    expect(track.getAttribute('data-progress-bar-fill-class-length')).toBe('19')
  })

  it('title attribute propagates to the track', () => {
    render(
      html`<${ProgressBar} pct=${50} title="67% complete" />`,
      container,
    )
    const track = container.querySelector('[data-progress-bar]')!
    expect(track.getAttribute('title')).toBe('67% complete')
    expect(track.getAttribute('data-progress-bar-has-title')).toBe('true')
    expect(track.getAttribute('data-progress-bar-title-length')).toBe('12')
  })

  it('size variant reflected in data attribute + height class', () => {
    render(html`<${ProgressBar} pct=${50} size="md" />`, container)
    const track = container.querySelector('[data-progress-bar]') as HTMLElement
    expect(track.getAttribute('data-progress-bar-size')).toBe('md')
    expect(track.className).toContain('h-2')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${ProgressBar} pct=${50} testId="build-progress" />`,
      container,
    )
    const track = container.querySelector('[data-testid="build-progress"]')!
    expect(track).toBeTruthy()
    expect(track.getAttribute('data-progress-bar-has-test-id')).toBe('true')
    expect(track.getAttribute('data-progress-bar-test-id-length')).toBe('14')
  })
})
