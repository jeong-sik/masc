// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { StatusDot } from './status-dot'

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
    expect(el.className).toContain('inline-block')
    expect(el.className).toContain('rounded-full')
    expect(el.className).toContain('shrink-0')
    expect(el.className).toContain('w-2 h-2')
    expect(el.getAttribute('data-status-dot-size')).toBe('sm')
    expect(el.getAttribute('data-status-dot-mode')).toBe('decorative')
    expect(el.getAttribute('data-status-dot-has-custom-class')).toBe('false')
    expect(el.getAttribute('data-status-dot-has-aria-label')).toBe('false')
    expect(el.getAttribute('data-status-dot-class-length')).toBe('0')
  })

  it('tone class (passed via `class`) ends up on the span', () => {
    const tone = 'bg-[var(--ok-10)] ml-1'
    render(html`<${StatusDot} class=${tone} />`, container)
    const el = container.querySelector('[data-status-dot]')!
    expect(el.className).toContain(tone)
    expect(el.getAttribute('data-status-dot-has-custom-class')).toBe('true')
    expect(el.getAttribute('data-status-dot-class-length')).toBe(String(tone.length))
  })

  it('default (no ariaLabel) is decorative — aria-hidden=true, no role', () => {
    // Regression guard: dot must NOT announce itself when paired with
    // a text label, otherwise AT users hear "dot, running, dot, stopped"
    // for every row. See Gate / transport-health tables.
    render(html`<${StatusDot} />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.getAttribute('role')).toBeNull()
  })

  it('ariaLabel promotes to semantic mode: role=img, no aria-hidden', () => {
    render(
      html`<${StatusDot} ariaLabel=" running " class="bg-[var(--ok-10)]" />`,
      container,
    )
    const el = container.querySelector('[data-status-dot]')!
    expect(el.getAttribute('role')).toBe('img')
    expect(el.getAttribute('aria-label')).toBe('running')
    expect(el.getAttribute('aria-hidden')).toBeNull()
    expect(el.getAttribute('data-status-dot-mode')).toBe('semantic')
    expect(el.getAttribute('data-status-dot-has-aria-label')).toBe('true')
  })

  it('empty ariaLabel remains decorative and omits a blank accessible name', () => {
    render(html`<${StatusDot} ariaLabel="   " />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el.getAttribute('role')).toBeNull()
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.getAttribute('aria-label')).toBeNull()
    expect(el.getAttribute('data-status-dot-mode')).toBe('decorative')
    expect(el.getAttribute('data-status-dot-has-aria-label')).toBe('false')
  })

  it('each size variant renders distinct Tailwind tokens', () => {
    const sizeClasses = {
      xs: 'w-1.5 h-1.5',
      sm: 'w-2 h-2',
      md: 'w-2.5 h-2.5',
      lg: 'w-3 h-3',
    } as const
    for (const [size, cls] of Object.entries(sizeClasses)) {
      render(html`<${StatusDot} size=${size} />`, container)
      const el = container.querySelector('[data-status-dot]') as HTMLElement
      expect(el.getAttribute('data-status-dot-size')).toBe(size)
      expect(el.className).toContain(cls)
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
