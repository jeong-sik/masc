// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Sep, type SepProps } from './sep'

describe('Sep', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: SepProps): HTMLElement {
    render(html`<${Sep} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a div with role=separator', () => {
    const el = mount({})
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('role')).toBe('separator')
  })

  it('defaults to horizontal orientation', () => {
    const el = mount({})
    expect(el.getAttribute('data-orientation')).toBe('horizontal')
    expect(el.getAttribute('aria-orientation')).toBe('horizontal')
  })

  it('records vertical orientation', () => {
    const el = mount({ orientation: 'vertical' })
    expect(el.getAttribute('data-orientation')).toBe('vertical')
    expect(el.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ testId: 'group-sep' })
    expect(el.getAttribute('data-testid')).toBe('group-sep')
  })

  it('records tone on data-tone', () => {
    const el = mount({ tone: 'strong' })
    expect(el.getAttribute('data-tone')).toBe('strong')
  })

  // ── SPEC geometry ──

  it('horizontal renders 1px height + 100% width', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('height: 1px')
    expect(style).toContain('width: 100%')
  })

  it('vertical renders 1px width + 16px height', () => {
    const el = mount({ orientation: 'vertical' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('width: 1px')
    expect(style).toContain('height: 16px')
  })

  it('horizontal uses 8px vertical margin (SPEC sp-2)', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('margin: 8px 0')
  })

  it('vertical uses 8px horizontal margin (SPEC sp-2)', () => {
    const el = mount({ orientation: 'vertical' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('margin: 0px 8px')
  })

  it('drops margin when noMargin=true', () => {
    const el = mount({ noMargin: true })
    const style = el.getAttribute('style') ?? ''
    expect(style).toMatch(/margin:\s*0(px)?\s*;/)
  })

  // ── Tone ──

  it('horizontal default uses border-default', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('background: var(--color-border-default)')
  })

  it('vertical default uses border-strong (SPEC per-orientation default)', () => {
    const el = mount({ orientation: 'vertical' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('background: var(--color-border-strong)')
  })

  it('horizontal with tone=strong upgrades to border-strong', () => {
    const el = mount({ tone: 'strong' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('background: var(--color-border-strong)')
  })

  // ── Layout ──

  it('horizontal is display: block', () => {
    const el = mount({})
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('display: block')
  })

  it('vertical is display: inline-block (drops between siblings)', () => {
    const el = mount({ orientation: 'vertical' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('display: inline-block')
  })

  it('vertical has flex-shrink: 0 (survives flex squeeze)', () => {
    const el = mount({ orientation: 'vertical' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('flex-shrink: 0')
  })
})
