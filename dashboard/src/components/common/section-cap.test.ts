// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { SectionCap, sectionCapClasses } from './section-cap'

describe('sectionCapClasses (pure)', () => {
  it('default (muted, normal) includes base tokens + muted tone + no weight', () => {
    const cls = sectionCapClasses()
    expect(cls).toContain('text-[10px]')
    expect(cls).toContain('uppercase')
    expect(cls).toContain('tracking-wider')
    expect(cls).toContain('text-text-muted')
    expect(cls).not.toContain('font-semibold')
  })

  it('dim tone swaps muted → dim (mutually exclusive)', () => {
    const cls = sectionCapClasses('dim')
    expect(cls).toContain('text-text-dim')
    expect(cls).not.toContain('text-text-muted')
  })

  it('semibold weight adds font-semibold', () => {
    expect(sectionCapClasses('muted', 'semibold')).toContain('font-semibold')
  })

  it('extra class is appended (caller composition)', () => {
    expect(sectionCapClasses('muted', 'normal', 'mb-1 flex')).toContain('mb-1 flex')
  })

  it('empty/undefined extra leaves the string tight (no trailing space)', () => {
    expect(sectionCapClasses('muted', 'normal', '')).not.toMatch(/\s$/)
    expect(sectionCapClasses('muted', 'normal', undefined)).not.toMatch(/\s$/)
  })

  it('base tokens always present across tone/weight combos (regression guard)', () => {
    // Drifting the base class breaks the 10px uppercase grid across
    // the 6 files the primitive unifies.
    for (const tone of ['muted', 'dim'] as const) {
      for (const weight of ['normal', 'semibold'] as const) {
        const cls = sectionCapClasses(tone, weight)
        for (const token of ['text-[10px]', 'uppercase', 'tracking-wider']) {
          expect(cls).toContain(token)
        }
      }
    }
  })
})

describe('SectionCap component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders <div data-section-cap> with children verbatim', () => {
    render(html`<${SectionCap}>성공률<//>`, container)
    const el = container.querySelector('[data-section-cap]')!
    expect(el.tagName).toBe('DIV')
    expect(el.textContent).toBe('성공률')
  })

  it('data-section-cap-tone/weight reflect props (default muted/normal)', () => {
    render(html`<${SectionCap}>Input<//>`, container)
    const el = container.querySelector('[data-section-cap]')!
    expect(el.getAttribute('data-section-cap-tone')).toBe('muted')
    expect(el.getAttribute('data-section-cap-weight')).toBe('normal')

    render(null, container)
    render(html`<${SectionCap} tone="dim" weight="semibold">시간대별 활동<//>`, container)
    const el2 = container.querySelector('[data-section-cap]')!
    expect(el2.getAttribute('data-section-cap-tone')).toBe('dim')
    expect(el2.getAttribute('data-section-cap-weight')).toBe('semibold')
  })

  it('testId propagates to data-testid', () => {
    render(html`<${SectionCap} testId="telemetry-freq-cap">호출 빈도<//>`, container)
    expect(container.querySelector('[data-testid="telemetry-freq-cap"]')).toBeTruthy()
  })

  it('class prop composes with primitive classes (caller layout preserved)', () => {
    render(html`<${SectionCap} class="mb-1 flex items-center gap-2">tag<//>`, container)
    const el = container.querySelector('[data-section-cap]')!
    const cls = el.getAttribute('class') ?? ''
    expect(cls).toContain('text-[10px]')
    expect(cls).toContain('mb-1')
    expect(cls).toContain('flex')
  })
})
