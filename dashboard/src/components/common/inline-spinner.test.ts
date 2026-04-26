// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  InlineSpinner,
  inlineSpinnerClasses,
  inlineSpinnerSizeClass,
  inlineSpinnerToneClass,
} from './inline-spinner'

describe('inlineSpinnerSizeClass (pure)', () => {
  it('default is sm — the most common pre-change variant (h-3 w-3)', () => {
    expect(inlineSpinnerSizeClass()).toBe('h-2.5 w-2.5 border-2'.replace('h-2.5 w-2.5', 'h-3 w-3'))
    // equivalent assertion without the string surgery:
    expect(inlineSpinnerSizeClass('sm')).toBe('h-3 w-3 border-2')
  })

  it('each size maps to its expected Tailwind triple', () => {
    expect(inlineSpinnerSizeClass('xs')).toBe('h-2.5 w-2.5 border-2')
    expect(inlineSpinnerSizeClass('sm')).toBe('h-3 w-3 border-2')
    expect(inlineSpinnerSizeClass('md')).toBe('h-4 w-4 border-2')
  })
})

describe('inlineSpinnerToneClass (pure)', () => {
  it('accent tone uses the --accent CSS var (the dashboard brand hue)', () => {
    expect(inlineSpinnerToneClass('accent')).toContain('var(--color-accent-fg)')
    expect(inlineSpinnerToneClass('accent')).toContain('border-t-transparent')
  })

  it('muted tone uses --text-dim for background-sync contexts', () => {
    expect(inlineSpinnerToneClass('muted')).toContain('var(--color-fg-disabled)')
    expect(inlineSpinnerToneClass('muted')).toContain('border-t-transparent')
  })
})

describe('inlineSpinnerClasses (pure)', () => {
  it('always includes invariant base (inline-block, rounded-full, animate-spin, shrink-0)', () => {
    // Regression guard: drifting any of these breaks visual consistency
    // across the 5 call sites the primitive unifies.
    const cls = inlineSpinnerClasses()
    expect(cls).toContain('inline-block')
    expect(cls).toContain('rounded-full')
    expect(cls).toContain('animate-spin')
    expect(cls).toContain('shrink-0')
  })

  it('extra class is appended (caller composition)', () => {
    expect(inlineSpinnerClasses('sm', 'accent', 'mr-2')).toContain('mr-2')
  })

  it('empty/undefined extra leaves no trailing whitespace', () => {
    expect(inlineSpinnerClasses('sm', 'accent', '')).not.toMatch(/\s$/)
    expect(inlineSpinnerClasses('sm', 'accent', undefined)).not.toMatch(/\s$/)
  })
})

describe('InlineSpinner component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a span with data-inline-spinner + annotation attributes', () => {
    render(html`<${InlineSpinner} />`, container)
    const el = container.querySelector('[data-inline-spinner]') as HTMLElement
    expect(el.tagName).toBe('SPAN')
    expect(el.getAttribute('data-inline-spinner-size')).toBe('sm')
    expect(el.getAttribute('data-inline-spinner-tone')).toBe('accent')
  })

  it('size + tone reflect in data attributes', () => {
    render(html`<${InlineSpinner} size="md" tone="muted" />`, container)
    const el = container.querySelector('[data-inline-spinner]') as HTMLElement
    expect(el.getAttribute('data-inline-spinner-size')).toBe('md')
    expect(el.getAttribute('data-inline-spinner-tone')).toBe('muted')
  })

  it('default (no ariaLabel) is decorative — aria-hidden, no role', () => {
    // Regression guard: most callers sit the spinner next to an inline
    // text label (\"loading...\"). Announcing role=\"status\" here AND the
    // surrounding text is duplicative; operators rarely need the
    // spinner itself read out loud.
    render(html`<${InlineSpinner} />`, container)
    const el = container.querySelector('[data-inline-spinner]') as HTMLElement
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.getAttribute('role')).toBeNull()
  })

  it('ariaLabel promotes to semantic: role="status" + no aria-hidden', () => {
    render(
      html`<${InlineSpinner} ariaLabel="Loading tool metrics" />`,
      container,
    )
    const el = container.querySelector('[data-inline-spinner]')!
    expect(el.getAttribute('role')).toBe('status')
    expect(el.getAttribute('aria-label')).toBe('Loading tool metrics')
    expect(el.getAttribute('aria-hidden')).toBeNull()
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${InlineSpinner} testId="refresh-spinner" />`,
      container,
    )
    expect(container.querySelector('[data-testid="refresh-spinner"]')).toBeTruthy()
  })
})
