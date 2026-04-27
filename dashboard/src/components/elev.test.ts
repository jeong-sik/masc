// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Elev, resolveLevel, type ElevProps } from './elev'

describe('resolveLevel (pure)', () => {
  it('returns 0 when level is undefined', () => {
    expect(resolveLevel(undefined)).toBe(0)
  })

  it('passes through explicit levels 0..6', () => {
    for (const lvl of [0, 1, 2, 3, 4, 5, 6] as const) {
      expect(resolveLevel(lvl)).toBe(lvl)
    }
  })
})

describe('Elev', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: ElevProps): HTMLDivElement {
    render(html`<${Elev} ...${props} />`, host)
    return host.firstElementChild as HTMLDivElement
  }

  // ── Structural ──

  it('emits a <div> with data-elev', () => {
    const el = mount({ children: 'card', level: 2 })
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('data-elev')).toBe('2')
  })

  it('defaults to level 0 when omitted', () => {
    const el = mount({ children: 'inset' })
    expect(el.getAttribute('data-elev')).toBe('0')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: 'x', testId: 'modal-shell' })
    expect(el.getAttribute('data-testid')).toBe('modal-shell')
  })

  // ── Level fidelity (style attr inspection) ──

  it('level 0 is chromeless (no shadow, transparent border)', () => {
    const el = mount({ children: 'page', level: 0 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-page)')
    expect(style.toLowerCase()).toContain('transparent')
    expect(style).toContain('none')
  })

  it('level 1 uses panel-alt + thin downward shadow', () => {
    const el = mount({ children: 'panel', level: 1 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-panel-alt)')
    expect(style).toContain('0 1px 0')
  })

  it('level 2 uses elevated surface + inner highlight', () => {
    const el = mount({ children: 'card', level: 2 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-elevated)')
    expect(style).toContain('inset 0 1px 0')
  })

  it('level 3 introduces ambient drop shadow', () => {
    const el = mount({ children: 'hover', level: 3 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-hover)')
    expect(style).toContain('0 2px 6px')
  })

  it('level 4 uses popover stack with outset ring', () => {
    const el = mount({ children: 'menu', level: 4 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('0 6px 18px')
    expect(style).toContain('0 0 0 1px var(--color-border-strong)')
  })

  it('level 5 is drawer / sheet (12px drop)', () => {
    const el = mount({ children: 'drawer', level: 5 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('0 12px 32px')
  })

  it('level 6 is modal cap (24px drop, heaviest alpha)', () => {
    const el = mount({ children: 'modal', level: 6 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('0 24px 64px')
    expect(style).toContain('rgb(0 0 0 / 0.7)')
  })

  // ── Pass-through ──

  it('forwards user class for layout / geometry', () => {
    const el = mount({ children: 'x', level: 2, class: 'rounded-xs p-4' })
    expect(el.getAttribute('class')).toBe('rounded-xs p-4')
  })

  it('forwards role + aria-label for semantic surfaces', () => {
    const el = mount({
      children: 'x',
      level: 6,
      role: 'dialog',
      ariaLabel: 'Confirm retire',
    })
    expect(el.getAttribute('role')).toBe('dialog')
    expect(el.getAttribute('aria-label')).toBe('Confirm retire')
  })

  it('renders children', () => {
    const el = mount({ children: 'card body', level: 2 })
    expect(el.textContent).toContain('card body')
  })
})
