// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Band, type BandProps } from './band'

describe('Band', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: BandProps): HTMLElement {
    render(html`<${Band} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a div with aria-hidden=true (decorative)', () => {
    const el = mount({})
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('aria-hidden')).toBe('true')
  })

  it('records kind on data-kind', () => {
    const el = mount({ kind: 'ok' })
    expect(el.getAttribute('data-kind')).toBe('ok')
  })

  it('defaults to kind=default when omitted', () => {
    const el = mount({})
    expect(el.getAttribute('data-kind')).toBe('default')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ kind: 'warn', testId: 'card-band' })
    expect(el.getAttribute('data-testid')).toBe('card-band')
  })

  it('does NOT emit a role attribute (pure decoration)', () => {
    const el = mount({ kind: 'err' })
    expect(el.getAttribute('role')).toBe(null)
  })

  // ── Visual fidelity ──

  it('renders 2px height (SPEC band geometry)', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('height: 2px')
  })

  it('uses border-strong for default kind', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-border-strong)')
  })

  it('uses ok status token for ok kind', () => {
    const el = mount({ kind: 'ok' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-ok)')
  })

  it('uses warn status token for warn kind', () => {
    const el = mount({ kind: 'warn' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-warn)')
  })

  it('uses err status token for err kind', () => {
    const el = mount({ kind: 'err' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-err)')
  })

  it('uses stalled status token for stalled kind', () => {
    const el = mount({ kind: 'stalled' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-stalled)')
  })

  it('running kind uses accent foreground + glow box-shadow', () => {
    const el = mount({ kind: 'running' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-accent-fg)')
    expect(style).toContain('--color-accent-glow')
    expect(style).toContain('box-shadow')
  })

  it('non-running kinds do not emit box-shadow', () => {
    const el = mount({ kind: 'ok' })
    const style = el.getAttribute('style') ?? ''
    expect(style).not.toContain('box-shadow')
  })

  // ── Top radius ──

  it('renders top-only radius by default (1px 1px 0 0)', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    // happy-dom normalises bare `0` to `0px` in shorthand values
    expect(style).toMatch(/border-radius:\s*1px\s+1px\s+0(px)?\s+0(px)?/)
  })

  it('drops radius when topRadius=false', () => {
    const el = mount({ topRadius: false })
    const style = el.getAttribute('style') ?? ''
    expect(style).toMatch(/border-radius:\s*0(px)?\s*;/)
  })
})
