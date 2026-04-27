// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  TickerItem,
  TickerStrip,
  tickerItemAriaLabel,
  type TickerItemProps,
} from './ticker-item'

describe('tickerItemAriaLabel (pure)', () => {
  it('renders "keeper: text" for the minimal case', () => {
    expect(
      tickerItemAriaLabel({ keeperId: 'nick0cave', text: 'pushed PR #123' }),
    ).toBe('nick0cave: pushed PR #123')
  })

  it('inserts kind between keeper and colon (when not neutral)', () => {
    expect(
      tickerItemAriaLabel({ keeperId: 'qa-king', text: 'gate red', kind: 'err' }),
    ).toBe('qa-king err: gate red')
  })

  it('omits kind word when kind is "neutral"', () => {
    expect(
      tickerItemAriaLabel({ keeperId: 'sangsu', text: 'merged', kind: 'neutral' }),
    ).toBe('sangsu: merged')
  })

  it('appends ", at <time>" when time is given', () => {
    expect(
      tickerItemAriaLabel({
        keeperId: 'rama',
        text: 'merged',
        time: '14:32:18',
      }),
    ).toBe('rama: merged, at 14:32:18')
  })

  it('truncates body via bodyMaxChars (chunks pattern)', () => {
    expect(
      tickerItemAriaLabel({
        keeperId: 'a',
        text: 'this is a very long event description that overflows',
        bodyMaxChars: 10,
      }),
    ).toBe('a: this is a ')
  })

  it('skips truncation when bodyMaxChars is 0 or omitted', () => {
    expect(
      tickerItemAriaLabel({ keeperId: 'a', text: 'long body', bodyMaxChars: 0 }),
    ).toBe('a: long body')
  })

  it('combines kind + time + truncation', () => {
    expect(
      tickerItemAriaLabel({
        keeperId: 'masc-improver',
        text: 'reviewing audit cascade results',
        kind: 'warn',
        time: '09:01:15',
        bodyMaxChars: 8,
      }),
    ).toBe('masc-improver warn: reviewin, at 09:01:15')
  })
})

describe('TickerItem component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(props: TickerItemProps): HTMLElement {
    render(html`<${TickerItem} ...${props} />`, container)
    return container.querySelector('[role="listitem"]') as HTMLElement
  }

  it('renders role=listitem with the composed aria-label', () => {
    const el = mount({ keeperId: 'nick0cave', text: 'pushed PR #123' })
    expect(el).toBeTruthy()
    expect(el.getAttribute('role')).toBe('listitem')
    expect(el.getAttribute('aria-label')).toBe('nick0cave: pushed PR #123')
  })

  it('renders keeper id text alongside the sigil', () => {
    const el = mount({ keeperId: 'sangsu', text: 'merged' })
    expect(el.textContent).toContain('sangsu')
    expect(el.textContent).toContain('merged')
  })

  it('renders the trailing time chip by default', () => {
    const el = mount({
      keeperId: 'a',
      text: 'event',
      time: '14:32:18',
    })
    expect(el.textContent).toContain('14:32:18')
  })

  it('moves the time chip in front when timePosition=leading', () => {
    const el = mount({
      keeperId: 'a',
      text: 'event',
      time: '14:32:18',
      timePosition: 'leading',
    })
    const txt = el.textContent ?? ''
    expect(txt.indexOf('14:32:18')).toBeLessThan(txt.indexOf('a'))
  })

  it('omits time visually when timePosition=none', () => {
    const el = mount({
      keeperId: 'a',
      text: 'event',
      time: '14:32:18',
      timePosition: 'none',
    })
    expect(el.textContent).not.toContain('14:32:18')
    expect(el.getAttribute('aria-label')).toContain('14:32:18')
  })

  it('truncates body text in the visible row when bodyMaxChars given', () => {
    const long = 'this is a very long event description that overflows'
    const el = mount({ keeperId: 'a', text: long, bodyMaxChars: 8 })
    expect(el.textContent).toContain('this is ')
    expect(el.textContent).not.toContain('overflows')
  })

  it('renders the embedded KeeperBadge sigil span (sigil variant)', () => {
    const el = mount({ keeperId: 'nick0cave', text: 'event' })
    // For nick0cave (registry-pinned) the sigil is "NK".
    expect(el.textContent).toContain('NK')
  })
})

describe('TickerStrip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const sample: TickerItemProps[] = [
    { keeperId: 'nick0cave', text: 'pushed', time: '14:00:01' },
    { keeperId: 'qa-king', text: 'gate red', kind: 'err', time: '14:00:05' },
  ]

  it('renders role=log + aria-live=polite + default Korean aria-label', () => {
    render(html`<${TickerStrip} events=${sample} />`, container)
    const root = container.querySelector('[role="log"]')!
    expect(root.getAttribute('aria-live')).toBe('polite')
    expect(root.getAttribute('aria-label')).toBe('플릿 이벤트 티커')
  })

  it('renders one listitem per event', () => {
    render(html`<${TickerStrip} events=${sample} />`, container)
    expect(container.querySelectorAll('[role="listitem"]')).toHaveLength(2)
  })

  it('honors a caller-supplied aria-label', () => {
    render(
      html`<${TickerStrip} events=${sample} ariaLabel="A2A 활동 스트림" />`,
      container,
    )
    const root = container.querySelector('[role="log"]')!
    expect(root.getAttribute('aria-label')).toBe('A2A 활동 스트림')
  })

  it('vertical orientation stacks column-direction', () => {
    render(
      html`<${TickerStrip} events=${sample} orientation="vertical" />`,
      container,
    )
    const root = container.querySelector('[role="log"]') as HTMLElement
    expect(root.style.flexDirection).toBe('column')
  })

  it('horizontal orientation (default) uses row direction', () => {
    render(html`<${TickerStrip} events=${sample} />`, container)
    const root = container.querySelector('[role="log"]') as HTMLElement
    expect(root.style.flexDirection).toBe('row')
  })

  it('empty events array renders an empty log region', () => {
    render(html`<${TickerStrip} events=${[]} />`, container)
    expect(container.querySelector('[role="log"]')).toBeTruthy()
    expect(container.querySelectorAll('[role="listitem"]')).toHaveLength(0)
  })
})
