// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KvRow, type KvRowProps } from './kv-row'

describe('KvRow', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: KvRowProps): HTMLElement {
    render(html`<${KvRow} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a div as the host with data-kv-row marker', () => {
    const el = mount({ label: 'STATUS', value: 'ok' })
    expect(el.tagName).toBe('DIV')
    // preact serialises bare attribute markers as "true"
    expect(el.hasAttribute('data-kv-row')).toBe(true)
  })

  it('renders the label as the first child span with data-kv-key', () => {
    const el = mount({ label: 'STATUS', value: 'ok' })
    const k = el.querySelector('[data-kv-key]')
    expect(k).not.toBeNull()
    expect(k!.textContent).toBe('STATUS')
  })

  it('renders the value string in a data-kv-value span', () => {
    const el = mount({ label: 'STATUS', value: 'running' })
    const v = el.querySelector('[data-kv-value]')
    expect(v).not.toBeNull()
    expect(v!.textContent).toBe('running')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ label: 'X', value: 'y', testId: 'auth-row-1' })
    expect(el.getAttribute('data-testid')).toBe('auth-row-1')
  })

  // ── SPEC geometry ──

  it('uses 80px label column by default', () => {
    const el = mount({ label: 'X', value: 'y' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('grid-template-columns: 80px 1fr')
  })

  it('uses 120px label column when wide=true', () => {
    const el = mount({ label: 'X', value: 'y', wide: true })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('grid-template-columns: 120px 1fr')
  })

  it('records wide flag on data-kv-wide attribute', () => {
    const el = mount({ label: 'X', value: 'y', wide: true })
    expect(el.getAttribute('data-kv-wide')).toBe('true')
  })

  it('renders 12px column gap (SPEC sp-3)', () => {
    const el = mount({ label: 'X', value: 'y' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('gap: 12px')
  })

  it('renders baseline alignment (SPEC `.kv-row` rule)', () => {
    const el = mount({ label: 'X', value: 'y' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('align-items: baseline')
  })

  // ── Visual fidelity ──

  it('uses fg-muted for the key label', () => {
    const el = mount({ label: 'X', value: 'y' })
    const k = el.querySelector('[data-kv-key]') as HTMLElement
    const ks = k.getAttribute('style') ?? ''
    expect(ks).toContain('color: var(--color-fg-muted)')
    expect(ks).toContain('text-transform: uppercase')
    expect(ks).toContain('letter-spacing: 0.06em')
  })

  it('uses fg-primary mono for the value', () => {
    const el = mount({ label: 'X', value: 'y' })
    const v = el.querySelector('[data-kv-value]') as HTMLElement
    const vs = v.getAttribute('style') ?? ''
    expect(vs).toContain('color: var(--color-fg-primary)')
    expect(vs.toLowerCase()).toContain('monospace')
  })

  // ── Wrap opt-in ──

  it('value clips with ellipsis by default (nowrap)', () => {
    const el = mount({ label: 'X', value: 'long-id-that-should-clip' })
    const v = el.querySelector('[data-kv-value]') as HTMLElement
    const vs = v.getAttribute('style') ?? ''
    expect(vs).toContain('white-space: nowrap')
    expect(vs).toContain('text-overflow: ellipsis')
  })

  it('value wraps when wrap=true', () => {
    const el = mount({ label: 'X', value: 'long-id-that-should-wrap', wrap: true })
    const v = el.querySelector('[data-kv-value]') as HTMLElement
    const vs = v.getAttribute('style') ?? ''
    expect(vs).toContain('white-space: normal')
    expect(vs).toContain('word-break: break-all')
  })

  // ── Children override ──

  it('renders children instead of the value mono span when provided', () => {
    const el = mount({
      label: 'STATUS',
      children: html`<button data-custom>refresh</button>`,
    })
    const v = el.querySelector('[data-kv-value]')
    expect(v).toBeNull()
    expect(el.querySelector('[data-custom]')).not.toBeNull()
  })

  it('falls back to empty value when neither value nor children provided', () => {
    const el = mount({ label: 'STATUS' })
    const v = el.querySelector('[data-kv-value]') as HTMLElement
    expect(v).not.toBeNull()
    expect(v.textContent).toBe('')
  })
})
