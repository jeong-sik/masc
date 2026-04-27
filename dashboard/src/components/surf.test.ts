// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Surf, type SurfProps } from './surf'

describe('Surf', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: SurfProps): HTMLElement {
    render(html`<${Surf} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a div with data-kind', () => {
    const el = mount({ kind: 'err', children: 'fail' })
    expect(el.tagName).toBe('DIV')
    expect(el.getAttribute('data-kind')).toBe('err')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ kind: 'warn', children: 'hi', testId: 'banner' })
    expect(el.getAttribute('data-testid')).toBe('banner')
  })

  it('renders children content', () => {
    const el = mount({ kind: 'info', children: 'message body' })
    expect(el.textContent).toBe('message body')
  })

  it('forwards extra class string', () => {
    const el = mount({ kind: 'ok', children: 'x', class: 'mx-4 mb-2' })
    expect(el.getAttribute('class')).toContain('mx-4 mb-2')
  })

  // ── Aria role ──

  it('omits role by default', () => {
    const el = mount({ kind: 'ok', children: 'x' })
    expect(el.getAttribute('role')).toBe(null)
  })

  it('forwards role=alert', () => {
    const el = mount({ kind: 'err', children: 'x', role: 'alert' })
    expect(el.getAttribute('role')).toBe('alert')
  })

  it('forwards role=status', () => {
    const el = mount({ kind: 'info', children: 'x', role: 'status' })
    expect(el.getAttribute('role')).toBe('status')
  })

  // ── Kind tones (foreground only) ──
  //
  // happy-dom drops modern `rgb(var(--token) / alpha)` syntax from the
  // serialised style attribute — both `background` and `border-color`
  // are stripped. The fg `color` uses a plain `var()` and survives
  // serialisation, so we verify the fg per kind here. The 0.12 / 0.35
  // alpha layering and the glow channel are validated visually at
  // runtime (dev server) — this happy-dom limitation is documented in
  // surf.ts and matches the Pill / Chip test approach.

  it('uses status-ok foreground for ok kind', () => {
    const el = mount({ kind: 'ok', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-ok)')
  })

  it('uses status-warn foreground for warn kind', () => {
    const el = mount({ kind: 'warn', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-warn)')
  })

  it('uses status-err foreground for err kind', () => {
    const el = mount({ kind: 'err', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-err)')
  })

  it('uses status-info foreground for info kind', () => {
    const el = mount({ kind: 'info', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-info)')
  })

  it('uses status-stalled foreground for stalled kind', () => {
    const el = mount({ kind: 'stalled', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-stalled)')
  })

  it('uses accent-fg foreground for brass kind', () => {
    const el = mount({ kind: 'brass', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-accent-fg)')
  })

  it('uses longhand border-* (avoids happy-dom shorthand var() bug)', () => {
    const el = mount({ kind: 'err', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('border-width: 1px')
    expect(style).toContain('border-style: solid')
  })

  // ── Padding variants ──

  it('default padding is 12px 16px', () => {
    const el = mount({ kind: 'err', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('padding: 12px 16px')
  })

  it('tight padding is 8px 12px', () => {
    const el = mount({ kind: 'err', children: 'x', padding: 'tight' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('padding: 8px 12px')
  })

  it('loose padding is 16px 20px', () => {
    const el = mount({ kind: 'err', children: 'x', padding: 'loose' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('padding: 16px 20px')
  })

  // ── Border radius ──

  it('default border-radius is 6px', () => {
    const el = mount({ kind: 'err', children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('border-radius: 6px')
  })

  it('flat=true drops the radius', () => {
    const el = mount({ kind: 'err', children: 'x', flat: true })
    const style = el.getAttribute('style') ?? ''
    expect(style).toMatch(/border-radius:\s*0(px)?\s*;/)
  })
})
