/** @jsxImportSource solid-js */
// @vitest-environment happy-dom
//
// Mirrors `bar.test.ts` (Preact). Same DOM contract assertions on the
// Solid render path. Pure-helper tests (barPercent) reuse the
// Preact-equivalent fixtures verbatim — the function is pure and
// framework-agnostic, so it must produce identical results.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'solid-js/web'
import { Bar } from './bar.solid'
import { barPercent, type BarProps } from './bar-shared'

describe('barPercent (pure, Solid mirror)', () => {
  it('rounds to integer', () => {
    expect(barPercent(0)).toBe(0)
    expect(barPercent(50.4)).toBe(50)
    expect(barPercent(50.6)).toBe(51)
    expect(barPercent(100)).toBe(100)
  })

  it('clamps below 0 to 0', () => {
    expect(barPercent(-1)).toBe(0)
    expect(barPercent(-100)).toBe(0)
  })

  it('clamps above 100 to 100', () => {
    expect(barPercent(101)).toBe(100)
    expect(barPercent(9999)).toBe(100)
  })

  it('coerces NaN to 0', () => {
    expect(barPercent(Number.NaN)).toBe(0)
  })
})

describe('Bar (Solid)', () => {
  let host: HTMLDivElement
  let dispose: (() => void) | undefined

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    dispose?.()
    dispose = undefined
    host.remove()
  })

  function mount(props: BarProps): HTMLElement {
    dispose = render(() => <Bar {...props} />, host)
    return host.querySelector('[role="progressbar"]') as HTMLElement
  }

  // ── Structural ──

  it('emits a div with role=progressbar', () => {
    const el = mount({ value: 50 })
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('role')).toBe('progressbar')
  })

  it('exposes aria-valuenow/min/max', () => {
    const el = mount({ value: 42 })
    expect(el.getAttribute('aria-valuenow')).toBe('42')
    expect(el.getAttribute('aria-valuemin')).toBe('0')
    expect(el.getAttribute('aria-valuemax')).toBe('100')
  })

  it('defaults aria-label to the rounded percent', () => {
    const el = mount({ value: 67.4 })
    expect(el.getAttribute('aria-label')).toBe('67%')
  })

  it('lets caller override aria-label', () => {
    const el = mount({ value: 30, ariaLabel: '3 of 10 tasks complete' })
    expect(el.getAttribute('aria-label')).toBe('3 of 10 tasks complete')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ value: 50, testId: 'budget-bar' })
    expect(el.getAttribute('data-testid')).toBe('budget-bar')
  })

  it('records kind on data-kind', () => {
    const el = mount({ value: 50, kind: 'warn' })
    expect(el.getAttribute('data-kind')).toBe('warn')
  })

  it('defaults to kind=default when omitted', () => {
    const el = mount({ value: 50 })
    expect(el.getAttribute('data-kind')).toBe('default')
  })

  // ── Fill ──

  it('renders an inner fill span aria-hidden', () => {
    const el = mount({ value: 50 })
    const fill = el.querySelector('span[aria-hidden="true"]')
    expect(fill).not.toBeNull()
  })

  it('clamps value below 0 to 0% width', () => {
    const el = mount({ value: -5 })
    expect(el.getAttribute('aria-valuenow')).toBe('0')
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('width: 0%')
  })

  it('clamps value above 100 to 100% width', () => {
    const el = mount({ value: 150 })
    expect(el.getAttribute('aria-valuenow')).toBe('100')
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('width: 100%')
  })

  // ── Visual fidelity ──

  it('renders 4px height (SPEC bar geometry)', () => {
    const el = mount({ value: 50 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('4px')
  })

  it('uses elevated bg as track', () => {
    const el = mount({ value: 50 })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-bg-elevated)')
  })

  it('uses accent fill for default kind', () => {
    const el = mount({ value: 50 })
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('var(--color-accent-fg)')
  })

  it('uses ok status token for ok kind', () => {
    const el = mount({ value: 50, kind: 'ok' })
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('var(--color-status-ok)')
  })

  it('uses err status token for err kind', () => {
    const el = mount({ value: 50, kind: 'err' })
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('var(--color-status-err)')
  })

  // ── Transition ──

  it('applies width transition by default', () => {
    const el = mount({ value: 50 })
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    expect(fill.getAttribute('style') ?? '').toContain('transition')
  })

  it('drops transition when noTransition=true', () => {
    const el = mount({ value: 50, noTransition: true })
    const fill = el.querySelector('span[aria-hidden="true"]') as HTMLElement
    const style = fill.getAttribute('style') ?? ''
    expect(style).not.toContain('transition')
  })
})
