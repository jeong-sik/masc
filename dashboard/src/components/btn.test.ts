// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Btn, resolveVariant, type BtnProps } from './btn'

describe('resolveVariant (pure)', () => {
  it('returns "default" when variant is undefined', () => {
    expect(resolveVariant(undefined)).toBe('default')
  })

  it('passes through explicit variants', () => {
    expect(resolveVariant('primary')).toBe('primary')
    expect(resolveVariant('danger')).toBe('danger')
    expect(resolveVariant('ghost')).toBe('ghost')
  })
})

describe('Btn', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: BtnProps): HTMLButtonElement {
    render(html`<${Btn} ...${props} />`, host)
    return host.firstElementChild as HTMLButtonElement
  }

  // ── Structural ──

  it('emits a <button> with data-variant and data-size', () => {
    const el = mount({ children: 'SAVE', variant: 'primary', size: 'sm' })
    expect(el.tagName).toBe('BUTTON')
    expect(el.getAttribute('data-variant')).toBe('primary')
    expect(el.getAttribute('data-size')).toBe('sm')
  })

  it('defaults to variant=default / size=default when omitted', () => {
    const el = mount({ children: 'click' })
    expect(el.getAttribute('data-variant')).toBe('default')
    expect(el.getAttribute('data-size')).toBe('default')
  })

  it('defaults type to "button" (not submit) so it does not auto-submit forms', () => {
    const el = mount({ children: 'click' })
    expect(el.getAttribute('type')).toBe('button')
  })

  it('preserves explicit type="submit" for form callsites', () => {
    const el = mount({ children: 'Save', type: 'submit' })
    expect(el.getAttribute('type')).toBe('submit')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: 'X', testId: 'cancel-btn' })
    expect(el.getAttribute('data-testid')).toBe('cancel-btn')
  })

  // ── Click + disabled ──

  it('invokes onClick when activated', () => {
    const onClick = vi.fn()
    const el = mount({ children: 'click', onClick })
    el.click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('honors the disabled attribute', () => {
    const el = mount({ children: 'click', disabled: true })
    expect(el.disabled).toBe(true)
    expect(el.hasAttribute('disabled')).toBe(true)
  })

  it('does not emit disabled attribute when disabled is false/undefined', () => {
    const el = mount({ children: 'click' })
    expect(el.hasAttribute('disabled')).toBe(false)
  })

  // ── Variant fidelity (style attr inspection) ──

  it('primary uses brass accent surface', () => {
    const el = mount({ children: 'SAVE', variant: 'primary' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-accent-fg-dim)')
    expect(style).toContain('var(--color-bg-page)')
  })

  it('danger uses err status fg over a transparent surface', () => {
    // Note: happy-dom drops `border: 1px solid rgb(var(--x) / 0.4)`
    // shorthand because its CSS parser rejects custom-property arms,
    // so we assert the fg + transparent surface (matches chip.ts /
    // pill.ts test pattern). Border-color fidelity is verified by
    // primitives.html in the manual visual pass.
    const el = mount({ children: 'RETIRE', variant: 'danger' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-err)')
    expect(style.toLowerCase()).toContain('transparent')
  })

  it('ghost has transparent background and border', () => {
    const el = mount({ children: 'cancel', variant: 'ghost' })
    const style = el.getAttribute('style') ?? ''
    expect(style.toLowerCase()).toContain('transparent')
    expect(style).toContain('var(--color-fg-muted)')
  })

  it('default variant uses fg-secondary + border-default', () => {
    const el = mount({ children: 'click' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-fg-secondary)')
    expect(style).toContain('var(--color-border-default)')
  })

  // ── Size geometry ──

  it('xs is 18px tall with 0.06em letter-spacing', () => {
    const el = mount({ children: 'xs', size: 'xs' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('18px')
    expect(style).toContain('0.06em')
  })

  it('sm is 20px tall', () => {
    const el = mount({ children: 'sm', size: 'sm' })
    expect(el.getAttribute('style') ?? '').toContain('20px')
  })

  it('default is 24px tall', () => {
    const el = mount({ children: 'def' })
    expect(el.getAttribute('style') ?? '').toContain('24px')
  })

  it('lg is 28px tall (atom 11/14 codification — primitives.css addition)', () => {
    const el = mount({ children: 'lg', size: 'lg' })
    expect(el.getAttribute('style') ?? '').toContain('28px')
  })

  // ── Icon modifier ──

  it('icon flips geometry to 22×22 square and emits data-icon', () => {
    const el = mount({ children: '▸', icon: true, ariaLabel: 'expand' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('22px')
    expect(el.getAttribute('data-icon')).toBe('true')
  })

  it('non-icon button omits data-icon', () => {
    const el = mount({ children: 'click' })
    expect(el.getAttribute('data-icon')).toBe(null)
  })

  // ── Class + aria pass-through ──

  it('forwards user class without overwriting atom-owned style', () => {
    const el = mount({ children: 'click', class: 'mt-2 flex-1' })
    expect(el.getAttribute('class')).toBe('mt-2 flex-1')
  })

  it('forwards ariaLabel for icon-only buttons', () => {
    const el = mount({ children: '▸', icon: true, ariaLabel: 'expand row' })
    expect(el.getAttribute('aria-label')).toBe('expand row')
  })

  it('forwards title for native tooltip', () => {
    const el = mount({ children: 'X', title: 'close panel' })
    expect(el.getAttribute('title')).toBe('close panel')
  })
})
