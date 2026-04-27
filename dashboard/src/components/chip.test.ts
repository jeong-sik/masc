// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Chip, chipAriaLabel, type ChipProps } from './chip'

describe('chipAriaLabel (pure)', () => {
  it('returns the raw content when kind is undefined', () => {
    expect(chipAriaLabel({ children: '47 PASS' }, '47 PASS')).toBe('47 PASS')
  })

  it('appends (passing) for ok', () => {
    expect(
      chipAriaLabel({ children: '47 PASS', kind: 'ok' }, '47 PASS'),
    ).toBe('47 PASS (passing)')
  })

  it('appends (failing) for err', () => {
    expect(
      chipAriaLabel({ children: '3 FAIL', kind: 'err' }, '3 FAIL'),
    ).toBe('3 FAIL (failing)')
  })

  it('appends (warning) for warn', () => {
    expect(
      chipAriaLabel({ children: 'FLAKE', kind: 'warn' }, 'FLAKE'),
    ).toBe('FLAKE (warning)')
  })

  it('appends (stalled) for stalled', () => {
    expect(
      chipAriaLabel({ children: 'STALLED', kind: 'stalled' }, 'STALLED'),
    ).toBe('STALLED (stalled)')
  })

  it('lets caller override via ariaLabel', () => {
    expect(
      chipAriaLabel(
        { children: '3', kind: 'err', ariaLabel: '3 failed runs' },
        '3',
      ),
    ).toBe('3 failed runs')
  })

  it('does not append for neutral or ghost', () => {
    expect(chipAriaLabel({ children: 'tag', kind: 'neutral' }, 'tag')).toBe('tag')
    expect(chipAriaLabel({ children: 'tag', kind: 'ghost' }, 'tag')).toBe('tag')
  })
})

describe('Chip', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  function mount(props: ChipProps): HTMLElement {
    render(html`<${Chip} ...${props} />`, host)
    return host.firstElementChild as HTMLElement
  }

  // ── Structural ──

  it('emits a span with data-kind and data-size', () => {
    const el = mount({ children: 'P1', kind: 'brass', size: 'lg' })
    expect(el.tagName).toBe('SPAN')
    expect(el.getAttribute('data-kind')).toBe('brass')
    expect(el.getAttribute('data-size')).toBe('lg')
  })

  it('defaults to kind=neutral / size=default when omitted', () => {
    const el = mount({ children: 'tag' })
    expect(el.getAttribute('data-kind')).toBe('neutral')
    expect(el.getAttribute('data-size')).toBe('default')
  })

  it('forwards testId to data-testid', () => {
    const el = mount({ children: '47 PASS', kind: 'ok', testId: 'pass-chip' })
    expect(el.getAttribute('data-testid')).toBe('pass-chip')
  })

  // ── Aria + role ──

  it('sets role=status when kind is semantic (ok/warn/err/info/stalled/brass)', () => {
    const el = mount({ children: 'PASS', kind: 'ok' })
    expect(el.getAttribute('role')).toBe('status')
  })

  it('omits role when kind is neutral or ghost', () => {
    const neutral = mount({ children: 'tag', kind: 'neutral' })
    expect(neutral.getAttribute('role')).toBe(null)
    const ghost = mount({ children: 'tag', kind: 'ghost' })
    expect(ghost.getAttribute('role')).toBe(null)
  })

  it('encodes kind in aria-label suffix', () => {
    const el = mount({ children: '47 PASS', kind: 'ok' })
    expect(el.getAttribute('aria-label')).toBe('47 PASS (passing)')
  })

  // ── Dot variant ──

  it('renders a leading dot when dot=true and kind is semantic', () => {
    const el = mount({ children: 'PASS', kind: 'ok', dot: true })
    const dotEl = el.querySelector('span[aria-hidden="true"]')
    expect(dotEl).not.toBeNull()
  })

  it('omits the dot for neutral kind even when dot=true', () => {
    const el = mount({ children: 'tag', kind: 'neutral', dot: true })
    expect(el.querySelector('span[aria-hidden="true"]')).toBeNull()
  })

  it('omits the dot for ghost kind even when dot=true', () => {
    const el = mount({ children: 'tag', kind: 'ghost', dot: true })
    expect(el.querySelector('span[aria-hidden="true"]')).toBeNull()
  })

  it('omits the dot when dot is undefined', () => {
    const el = mount({ children: 'PASS', kind: 'ok' })
    expect(el.querySelector('span[aria-hidden="true"]')).toBeNull()
  })

  // ── Visual fidelity (style attr inspection) ──

  it('uses ok status token for foreground', () => {
    const el = mount({ children: 'PASS', kind: 'ok' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-status-ok)')
  })

  it('applies size geometry for sm', () => {
    const el = mount({ children: 'tag', size: 'sm' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('14px')
  })

  it('applies size geometry for lg', () => {
    const el = mount({ children: 'tag', size: 'lg' })
    const style = el.getAttribute('style') ?? ''
    expect(style).toContain('22px')
  })

  it('ghost has transparent background', () => {
    const el = mount({ children: 'tag', kind: 'ghost' })
    const style = el.getAttribute('style') ?? ''
    expect(style.toLowerCase()).toContain('transparent')
  })
})
