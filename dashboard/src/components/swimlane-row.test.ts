// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  SwimlaneRow,
  swimlaneEventStyle,
  swimlaneRowAriaLabel,
  type SwimlaneEvent,
  type SwimlaneRowProps,
} from './swimlane-row'

describe('swimlaneEventStyle (pure)', () => {
  it('point event (no width) returns left + neutral background', () => {
    const s = swimlaneEventStyle({ x: 0.5 })
    expect(s.left).toBe('50.00%')
    expect(s.width).toBeUndefined()
    expect(s.background).toContain('--color-fg-muted')
  })

  it('span event (width set) returns both left and width %', () => {
    const s = swimlaneEventStyle({ x: 0.1, width: 0.25 })
    expect(s.left).toBe('10.00%')
    expect(s.width).toBe('25.00%')
  })

  it('kind drives the background token', () => {
    expect(swimlaneEventStyle({ x: 0, kind: 'ok' }).background).toContain('--color-status-ok')
    expect(swimlaneEventStyle({ x: 0, kind: 'warn' }).background).toContain('--color-status-warn')
    expect(swimlaneEventStyle({ x: 0, kind: 'err' }).background).toContain('--color-status-err')
    expect(swimlaneEventStyle({ x: 0, kind: 'info' }).background).toContain('--color-accent-fg')
  })

  it('width=0 falls back to point rendering (no width returned)', () => {
    expect(swimlaneEventStyle({ x: 0.5, width: 0 }).width).toBeUndefined()
  })

  it('formats x to 2 decimal places', () => {
    expect(swimlaneEventStyle({ x: 0.123 }).left).toBe('12.30%')
  })
})

describe('swimlaneRowAriaLabel (pure)', () => {
  it('reports "no events" for an empty lane', () => {
    expect(
      swimlaneRowAriaLabel({ keeperId: 'nick0cave', events: [] }),
    ).toBe('nick0cave timeline: no events')
  })

  it('singular for one event', () => {
    expect(
      swimlaneRowAriaLabel({
        keeperId: 'sangsu',
        events: [{ x: 0.5 }],
      }),
    ).toBe('sangsu timeline: 1 event')
  })

  it('plural with last-kind tail when last event is non-neutral', () => {
    expect(
      swimlaneRowAriaLabel({
        keeperId: 'qa-king',
        events: [{ x: 0.1 }, { x: 0.5, kind: 'err' }],
      }),
    ).toBe('qa-king timeline: 2 events, last err')
  })

  it('omits last-kind tail when last event is neutral or omitted', () => {
    expect(
      swimlaneRowAriaLabel({
        keeperId: 'a',
        events: [{ x: 0.1, kind: 'err' }, { x: 0.5 }],
      }),
    ).toBe('a timeline: 2 events')
  })

  it('appends ", selected" when selected=true', () => {
    expect(
      swimlaneRowAriaLabel({
        keeperId: 'rama',
        events: [{ x: 0.5 }],
        selected: true,
      }),
    ).toBe('rama timeline: 1 event, selected')
  })

  it('caller-supplied ariaLabel wins (composition skipped)', () => {
    expect(
      swimlaneRowAriaLabel({
        keeperId: 'x',
        events: [{ x: 0.1 }],
        ariaLabel: 'Custom announcement',
      }),
    ).toBe('Custom announcement')
  })
})

describe('SwimlaneRow component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(props: SwimlaneRowProps): HTMLElement {
    render(html`<${SwimlaneRow} ...${props} />`, container)
    return container.querySelector('[role="listitem"]') as HTMLElement
  }

  it('renders role=listitem with composed aria-label', () => {
    const el = mount({
      keeperId: 'nick0cave',
      events: [{ x: 0.5 }],
    })
    expect(el).toBeTruthy()
    expect(el.getAttribute('role')).toBe('listitem')
    expect(el.getAttribute('aria-label')).toBe('nick0cave timeline: 1 event')
  })

  it('renders a KeeperBadge sigil + the keeper id text in the head', () => {
    const el = mount({ keeperId: 'nick0cave', events: [] })
    // Registry-pinned sigil for nick0cave is "NK"
    expect(el.textContent).toContain('NK')
    expect(el.textContent).toContain('nick0cave')
  })

  it('renders one positioned span per event (track children)', () => {
    const events: SwimlaneEvent[] = [
      { x: 0.1 },
      { x: 0.5, kind: 'ok' },
      { x: 0.8, kind: 'err' },
    ]
    const el = mount({ keeperId: 'a', events })
    const track = el.querySelector('div[aria-hidden="true"]')!
    expect(track.children.length).toBe(3)
  })

  it('point event sets fixed 4px width + negative margin offset', () => {
    const el = mount({ keeperId: 'a', events: [{ x: 0.5 }] })
    const span = el.querySelector('div[aria-hidden="true"] span') as HTMLElement
    expect(span.style.width).toBe('4px')
    expect(span.style.marginLeft).toBe('-2px')
  })

  it('span event uses percentage width (Bars pattern)', () => {
    const el = mount({
      keeperId: 'a',
      events: [{ x: 0.1, width: 0.4, kind: 'ok' }],
    })
    const span = el.querySelector('div[aria-hidden="true"] span') as HTMLElement
    expect(span.style.width).toBe('40.00%')
    expect(span.style.left).toBe('10.00%')
  })

  it('non-interactive lane omits tabindex and click handlers', () => {
    const el = mount({ keeperId: 'a', events: [{ x: 0.5 }] })
    expect(el.getAttribute('tabindex')).toBeNull()
  })

  it('interactive lane sets tabindex=0 and fires onActivate on click', () => {
    const onActivate = vi.fn()
    render(
      html`<${SwimlaneRow} keeperId="a" events=${[]} onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    expect(el.getAttribute('tabindex')).toBe('0')
    el.click()
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('Enter key activates an interactive lane', () => {
    const onActivate = vi.fn()
    render(
      html`<${SwimlaneRow} keeperId="a" events=${[]} onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('Space key activates an interactive lane', () => {
    const onActivate = vi.fn()
    render(
      html`<${SwimlaneRow} keeperId="a" events=${[]} onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('selected=true emits aria-current="true"', () => {
    const el = mount({ keeperId: 'a', events: [], selected: true })
    expect(el.getAttribute('aria-current')).toBe('true')
  })

  it('selected=false omits aria-current', () => {
    const el = mount({ keeperId: 'a', events: [] })
    expect(el.getAttribute('aria-current')).toBeNull()
  })
})
