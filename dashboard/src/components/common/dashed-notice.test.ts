// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { DashedNotice, dashedNoticeClasses } from './dashed-notice'

describe('dashedNoticeClasses (pure)', () => {
  it('default is sm + card (the most common pre-change variant)', () => {
    const cls = dashedNoticeClasses()
    expect(cls).toBe(dashedNoticeClasses('sm', 'card'))
  })

  it('always includes base invariants (dashed border, center text, text-dim)', () => {
    // Regression guard: drifting any of these tokens breaks visual
    // consistency across the 9 call sites the primitive unifies.
    const cls = dashedNoticeClasses()
    expect(cls).toContain('border-dashed')
    expect(cls).toContain('text-center')
    expect(cls).toContain('text-[var(--color-fg-disabled)]')
  })

  it('sm size: 10px text + rounded + tight padding (matches fsm-hub timeline panels)', () => {
    const cls = dashedNoticeClasses('sm')
    expect(cls).toContain('text-3xs')
    expect(cls).toContain('rounded')
    expect(cls).toContain('px-4')
    expect(cls).toContain('py-2')
  })

  it('md size: 12px text + rounded + generous padding', () => {
    const cls = dashedNoticeClasses('md')
    expect(cls).toContain('text-xs')
    expect(cls).toContain('rounded')
    expect(cls).toContain('px-4')
    expect(cls).toContain('py-6')
  })

  it('card border tone uses --card-border', () => {
    expect(dashedNoticeClasses('sm', 'card')).toContain('border-[var(--color-border-default)]')
  })

  it('subtle border tone uses --white-8 (dimmer)', () => {
    expect(dashedNoticeClasses('sm', 'subtle')).toContain('border-[var(--white-8)]')
  })

  it('extra class is appended (caller composition)', () => {
    expect(dashedNoticeClasses('sm', 'card', 'mt-3')).toContain('mt-3')
  })

  it('empty/undefined extra class leaves no trailing whitespace', () => {
    expect(dashedNoticeClasses('sm', 'card', '')).not.toMatch(/\s$/)
    expect(dashedNoticeClasses('sm', 'card', undefined)).not.toMatch(/\s$/)
  })
})

describe('DashedNotice component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a div with data-dashed-notice + attribute annotations', () => {
    render(html`<${DashedNotice}>still empty<//>`, container)
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('data-dashed-notice-size')).toBe('sm')
    expect(el.getAttribute('data-dashed-notice-border')).toBe('card')
    expect(el.textContent).toBe('still empty')
  })

  it('size + borderTone reflect in data attributes', () => {
    render(
      html`<${DashedNotice} size="md" borderTone="subtle">big empty<//>`,
      container,
    )
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.getAttribute('data-dashed-notice-size')).toBe('md')
    expect(el.getAttribute('data-dashed-notice-border')).toBe('subtle')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${DashedNotice} testId="runs-empty">no runs<//>`,
      container,
    )
    expect(container.querySelector('[data-testid="runs-empty"]')).toBeTruthy()
  })

  it('accepts arbitrary preact children (markup, not just strings)', () => {
    render(
      html`<${DashedNotice}>
        <strong>heads up</strong> — nothing yet
      <//>`,
      container,
    )
    const el = container.querySelector('[data-dashed-notice]') as HTMLElement
    expect(el.querySelector('strong')?.textContent).toBe('heads up')
  })
})
