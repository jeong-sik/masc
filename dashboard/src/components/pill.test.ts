// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Pill, pillAriaLabel, type PillProps } from './pill'

describe('pillAriaLabel (pure)', () => {
  it('returns raw content when kind is undefined or neutral', () => {
    expect(pillAriaLabel({ children: 'IDLE' }, 'IDLE')).toBe('IDLE')
    expect(
      pillAriaLabel({ children: 'IDLE', kind: 'neutral' }, 'IDLE'),
    ).toBe('IDLE')
  })

  it('appends (running) for running', () => {
    expect(
      pillAriaLabel({ children: 'RUN', kind: 'running' }, 'RUN'),
    ).toBe('RUN (running)')
  })

  it('appends (paused) for paused', () => {
    expect(
      pillAriaLabel({ children: 'PAUSE', kind: 'paused' }, 'PAUSE'),
    ).toBe('PAUSE (paused)')
  })

  it('appends (failing) for err', () => {
    expect(
      pillAriaLabel({ children: 'ERR', kind: 'err' }, 'ERR'),
    ).toBe('ERR (failing)')
  })

  it('lets caller override via ariaLabel', () => {
    expect(
      pillAriaLabel(
        { children: 'X', kind: 'err', ariaLabel: 'critical error' },
        'X',
      ),
    ).toBe('critical error')
  })
})

describe('Pill', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: PillProps): HTMLElement {
    render(html`<${Pill} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a span with data-kind', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    expect(el.tagName).toBe('SPAN')
    expect(el.getAttribute('data-kind')).toBe('running')
  })

  it('defaults to kind=neutral when omitted', () => {
    const el = mount({ children: 'tag' })
    expect(el.getAttribute('data-kind')).toBe('neutral')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: 'RUN', kind: 'running', testId: 'run-pill' })
    expect(el.getAttribute('data-testid')).toBe('run-pill')
  })

  // ── Aria + role ──

  it('sets role=status for stateful kinds', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    expect(el.getAttribute('role')).toBe('status')
    const ok = mount({ children: 'OK', kind: 'ok' })
    expect(ok.getAttribute('role')).toBe('status')
  })

  it('omits role when kind is neutral', () => {
    const el = mount({ children: 'tag', kind: 'neutral' })
    expect(el.getAttribute('role')).toBe(null)
  })

  it('encodes kind in aria-label suffix', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    expect(el.getAttribute('aria-label')).toBe('RUN (running)')
  })

  // ── Dot variant ──

  it('renders a leading dot when dot=true and kind is stateful', () => {
    const el = mount({ children: 'RUN', kind: 'running', dot: true })
    expect(el.querySelector('span[aria-hidden="true"]')).not.toBeNull()
  })

  it('omits the dot for neutral kind even when dot=true', () => {
    const el = mount({ children: 'tag', kind: 'neutral', dot: true })
    expect(el.querySelector('span[aria-hidden="true"]')).toBeNull()
  })

  it('omits the dot when dot is undefined', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    expect(el.querySelector('span[aria-hidden="true"]')).toBeNull()
  })

  // ── Visual fidelity (style attr inspection) ──

  it('uses accent token for running foreground', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-accent-fg)')
  })

  it('uses ok status token for ok foreground', () => {
    const el = mount({ children: 'OK', kind: 'ok' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-ok)')
  })

  it('renders capsule shape (border-radius: 999px)', () => {
    const el = mount({ children: 'RUN', kind: 'running' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('999px')
  })

  it('renders 16px height (SPEC pill geometry)', () => {
    const el = mount({ children: 'tag' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('16px')
  })
})
