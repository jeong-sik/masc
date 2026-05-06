// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  StatusDot,
  summarizeStatusDot,
  statusDotClasses,
  statusDotSizeClass,
} from './status-dot'

describe('statusDotSizeClass (pure)', () => {
  it('default size is sm (8px — baseline row marker)', () => {
    expect(statusDotSizeClass()).toBe('w-2 h-2')
  })

  it('produces the expected Tailwind pair for each named variant', () => {
    expect(statusDotSizeClass('xs')).toBe('w-1.5 h-1.5')
    expect(statusDotSizeClass('sm')).toBe('w-2 h-2')
    expect(statusDotSizeClass('md')).toBe('w-2.5 h-2.5')
    expect(statusDotSizeClass('lg')).toBe('w-3 h-3')
  })
})

describe('statusDotClasses (pure)', () => {
  it('always includes the invariant base (rounded-full + shrink-0 + inline-block)', () => {
    const cls = statusDotClasses()
    expect(cls).toContain('rounded-full')
    expect(cls).toContain('shrink-0')
    expect(cls).toContain('inline-block')
  })

  it('tone class is appended after size (caller controls color)', () => {
    const cls = statusDotClasses('sm', 'bg-[var(--ok-10)]')
    expect(cls).toContain('w-2 h-2')
    expect(cls).toContain('bg-[var(--ok-10)]')
  })

  it('empty / undefined tone does not leave trailing whitespace', () => {
    expect(statusDotClasses('sm', '')).not.toMatch(/\s$/)
    expect(statusDotClasses('sm', undefined)).not.toMatch(/\s$/)
  })

  it('extra class appended after tone (margin, ring, etc.)', () => {
    const cls = statusDotClasses('sm', 'bg-[var(--bad-10)]', 'ml-1')
    expect(cls).toContain('bg-[var(--bad-10)]')
    expect(cls).toContain('ml-1')
    expect(cls.indexOf('bg-[var(--bad-10)]')).toBeLessThan(cls.indexOf('ml-1'))
  })
})

describe('summarizeStatusDot (pure)', () => {
  it('summarizes the decorative default without reading the DOM', () => {
    expect(summarizeStatusDot({})).toEqual({
      size: 'sm',
      mode: 'decorative',
      hasCustomClass: false,
      hasAriaLabel: false,
      classNameLength: 0,
    })
  })

  it('summarizes semantic dots with tone metadata', () => {
    const tone = 'bg-[var(--ok-10)] ring-1'
    expect(summarizeStatusDot({ size: 'md', className: tone, ariaLabel: 'healthy' })).toEqual({
      size: 'md',
      mode: 'semantic',
      hasCustomClass: true,
      hasAriaLabel: true,
      classNameLength: tone.length,
    })
  })
})

describe('StatusDot component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a span with data-status-dot + size attribute', () => {
    render(html`<${StatusDot} />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el.tagName).toBe('SPAN')
    expect(el.getAttribute('data-status-dot-size')).toBe('sm')
    expect(el.getAttribute('data-status-dot-mode')).toBe('decorative')
    expect(el.getAttribute('data-status-dot-has-custom-class')).toBe('false')
    expect(el.getAttribute('data-status-dot-has-aria-label')).toBe('false')
    expect(el.getAttribute('data-status-dot-class-length')).toBe('0')
  })

  it('tone class (passed via `class`) ends up on the span', () => {
    const tone = 'bg-[var(--ok-10)]'
    render(html`<${StatusDot} class=${tone} />`, container)
    const el = container.querySelector('[data-status-dot]')!
    expect(el.className).toContain(tone)
    expect(el.getAttribute('data-status-dot-has-custom-class')).toBe('true')
    expect(el.getAttribute('data-status-dot-class-length')).toBe(String(tone.length))
  })

  it('default (no ariaLabel) is decorative — aria-hidden=true, no role', () => {
    // Regression guard: dot must NOT announce itself when paired with
    // a text label, otherwise AT users hear "dot, running, dot, stopped"
    // for every row. See governance / transport-health tables.
    render(html`<${StatusDot} />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.getAttribute('role')).toBeNull()
  })

  it('ariaLabel promotes to semantic mode: role=img, no aria-hidden', () => {
    render(
      html`<${StatusDot} ariaLabel="running" class="bg-[var(--ok-10)]" />`,
      container,
    )
    const el = container.querySelector('[data-status-dot]')!
    expect(el.getAttribute('role')).toBe('img')
    expect(el.getAttribute('aria-label')).toBe('running')
    expect(el.getAttribute('aria-hidden')).toBeNull()
    expect(el.getAttribute('data-status-dot-mode')).toBe('semantic')
    expect(el.getAttribute('data-status-dot-has-aria-label')).toBe('true')
  })

  it('each size variant renders distinct Tailwind tokens', () => {
    for (const size of ['xs', 'sm', 'md', 'lg'] as const) {
      render(html`<${StatusDot} size=${size} />`, container)
      const el = container.querySelector('[data-status-dot]') as HTMLElement
      expect(el.getAttribute('data-status-dot-size')).toBe(size)
      render(null, container)
    }
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${StatusDot} testId="transport-sse-dot" class="bg-[var(--ok-10)]" />`,
      container,
    )
    expect(container.querySelector('[data-testid="transport-sse-dot"]')).toBeTruthy()
  })
})
