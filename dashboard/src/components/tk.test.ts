// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Tk, type TkProps } from './tk'

describe('Tk', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: TkProps): HTMLElement {
    render(html`<${Tk} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a <code> tag by default (semantic match)', () => {
    const el = mount({ children: 'foo' })
    expect(el.tagName).toBe('CODE')
  })

  it('renders as <span> when as="span"', () => {
    const el = mount({ children: 'bar', as: 'span' })
    expect(el.tagName).toBe('SPAN')
  })

  it('records kind on data-kind', () => {
    const el = mount({ children: 'x', kind: 'brass' })
    expect(el.getAttribute('data-kind')).toBe('brass')
  })

  it('defaults to kind=default when omitted', () => {
    const el = mount({ children: 'x' })
    expect(el.getAttribute('data-kind')).toBe('default')
  })

  it('marks the host with data-tk for selectors', () => {
    const el = mount({ children: 'x' })
    expect(el.hasAttribute('data-tk')).toBe(true)
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: 'TASK_ID', testId: 'task-token' })
    expect(el.getAttribute('data-testid')).toBe('task-token')
  })

  it('forwards title attribute', () => {
    const el = mount({ children: 'X', title: 'environment variable' })
    expect(el.getAttribute('title')).toBe('environment variable')
  })

  it('renders children content', () => {
    const el = mount({ children: 'TASK_ID' })
    expect(el.textContent).toBe('TASK_ID')
  })

  // ── SPEC font / geometry ──

  it('uses monospace font stack', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style.toLowerCase()).toContain('monospace')
  })

  it('uses SPEC 0.92em relative font-size (sits in surrounding prose)', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('font-size: 0.92em')
  })

  it('uses SPEC 0 4px padding', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('padding: 0px 4px')
  })

  it('uses SPEC 2px border-radius', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('border-radius: 2px')
  })

  it('clips overflow with ellipsis (extreme values)', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('white-space: nowrap')
    expect(style).toContain('text-overflow: ellipsis')
  })

  // ── Kind tones (fg only — happy-dom drops modern rgb()/var()/alpha) ──

  it('uses fg-primary for default kind', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-fg-primary)')
  })

  it('uses accent-fg for brass kind', () => {
    const el = mount({ children: 'x', kind: 'brass' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-accent-fg)')
  })

  it('uses status-err for err kind', () => {
    const el = mount({ children: 'x', kind: 'err' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('color: var(--color-status-err)')
  })

  it('uses bg-elevated for default background (plain var, survives serialisation)', () => {
    const el = mount({ children: 'x' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('background: var(--color-bg-elevated)')
  })
})
