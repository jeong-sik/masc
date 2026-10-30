// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { SectionHead, type SectionHeadProps } from './section-head'

describe('SectionHead', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: SectionHeadProps): HTMLElement {
    render(html`<${SectionHead} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a div as the host', () => {
    const el = mount({ children: 'KEEPERS' })
    expect(el.tagName).toBe('DIV')
  })

  it('renders the label as the first child span', () => {
    const el = mount({ children: 'KEEPERS' })
    const first = el.firstElementChild as HTMLElement
    expect(first.tagName).toBe('SPAN')
    expect(first.textContent).toBe('KEEPERS')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: 'X', testId: 'overview-head' })
    expect(el.getAttribute('data-testid')).toBe('overview-head')
  })

  it('lets caller set aria-label', () => {
    const el = mount({ children: 'X', ariaLabel: 'panel header' })
    expect(el.getAttribute('aria-label')).toBe('panel header')
  })

  // ── SPEC geometry ──

  it('renders 28px min-height (SPEC strip geometry)', () => {
    const el = mount({ children: 'X' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('min-height: 28px')
  })

  it('renders 12px horizontal padding', () => {
    const el = mount({ children: 'X' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('padding: 0px 12px')
  })

  it('renders bottom hairline by default', () => {
    const el = mount({ children: 'X' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('border-bottom-width: 1px')
    expect(style).toContain('border-bottom-style: solid')
    expect(style).toContain('border-bottom-color: var(--color-border-default)')
  })

  it('drops bottom hairline when noBorder=true', () => {
    const el = mount({ children: 'X', noBorder: true })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('border-bottom-style: none')
  })

  // ── Visual fidelity ──

  it('uses bg-surface as the strip background', () => {
    const el = mount({ children: 'X' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-surface)')
  })

  it('uses fg-muted for the label tone', () => {
    const el = mount({ children: 'X' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-fg-muted)')
  })

  it('applies uppercase + 0.08em letter-spacing (SPEC font rule)', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('text-transform: uppercase')
    expect(style).toContain('letter-spacing: 0.08em')
  })

  // ── Count slot ──

  it('omits count span when count is undefined', () => {
    const el = mount({ children: 'X' })
    expect(el.querySelector('[data-section-head-count]')).toBeNull()
  })

  it('renders count as tabular-nums right-aligned span', () => {
    const el = mount({ children: 'KEEPERS', count: 14 })
    const cnt = el.querySelector('[data-section-head-count]') as HTMLElement
    expect(cnt).not.toBeNull()
    expect(cnt.textContent).toBe('14')
    const cs = cnt.getAttribute('style') ?? ''
    expect(cs).toContain('font-variant-numeric: tabular-nums')
    expect(cs).toContain('margin-left: auto')
  })

  it('accepts a string count', () => {
    const el = mount({ children: 'X', count: '7/12' })
    const cnt = el.querySelector('[data-section-head-count]') as HTMLElement
    expect(cnt.textContent).toBe('7/12')
  })

  // ── Tail slot ──

  it('omits tail span when tail is undefined', () => {
    const el = mount({ children: 'X' })
    expect(el.querySelector('[data-section-head-tail]')).toBeNull()
  })

  it('renders tail as a right-aligned flex container', () => {
    const el = mount({
      children: 'X',
      tail: html`<button>refresh</button>`,
    })
    const tail = el.querySelector('[data-section-head-tail]') as HTMLElement
    expect(tail).not.toBeNull()
    const ts = tail.getAttribute('style') ?? ''
    expect(ts).toContain('margin-left: auto')
    expect(ts).toContain('display: inline-flex')
  })

  it('when both count and tail present, count pushes right and tail follows', () => {
    const el = mount({
      children: 'X',
      count: 3,
      tail: html`<button>x</button>`,
    })
    const cnt = el.querySelector('[data-section-head-count]')
    const tail = el.querySelector('[data-section-head-tail]') as HTMLElement
    expect(cnt).not.toBeNull()
    expect(tail).not.toBeNull()
    // tail uses 8px gap not auto when count claims the auto slot
    const ts = tail.getAttribute('style') ?? ''
    expect(ts).toContain('margin-left: 8px')
  })
})
