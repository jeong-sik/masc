// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { SidebarRow, sidebarRowAriaLabel, type SidebarRowProps } from './sidebar-row'

describe('sidebarRowAriaLabel (pure)', () => {
  it('returns "keeperId" for the minimal case', () => {
    expect(sidebarRowAriaLabel({ keeperId: 'nick0cave' })).toBe('nick0cave')
  })

  it('appends meta when given', () => {
    expect(
      sidebarRowAriaLabel({ keeperId: 'nick0cave', meta: 'fixing CI' }),
    ).toBe('nick0cave · fixing CI')
  })

  it('appends status when given', () => {
    expect(
      sidebarRowAriaLabel({ keeperId: 'a', status: 'running' }),
    ).toBe('a · running')
  })

  it('combines meta + status + selected in canonical order', () => {
    expect(
      sidebarRowAriaLabel({
        keeperId: 'nick0cave',
        meta: 'PK-101',
        status: 'running',
        selected: true,
      }),
    ).toBe('nick0cave · PK-101 · running · selected')
  })

  it('caller-supplied ariaLabel wins', () => {
    expect(
      sidebarRowAriaLabel({
        keeperId: 'a',
        meta: 'm',
        ariaLabel: 'Custom',
      }),
    ).toBe('Custom')
  })
})

describe('SidebarRow component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(props: SidebarRowProps): HTMLElement {
    render(html`<${SidebarRow} ...${props} />`, container)
    return container.querySelector('[role="listitem"]') as HTMLElement
  }

  it('renders role=listitem with composed aria-label', () => {
    const el = mount({ keeperId: 'nick0cave' })
    expect(el).toBeTruthy()
    expect(el.getAttribute('role')).toBe('listitem')
    expect(el.getAttribute('aria-label')).toBe('nick0cave')
  })

  it('renders KeeperBadge sigil + keeper id text', () => {
    const el = mount({ keeperId: 'nick0cave' })
    expect(el.textContent).toContain('NK')
    expect(el.textContent).toContain('nick0cave')
  })

  it('renders meta text when given', () => {
    const el = mount({ keeperId: 'a', meta: 'PK-101' })
    expect(el.textContent).toContain('PK-101')
  })

  it('omits meta span when not given', () => {
    const el = mount({ keeperId: 'a' })
    // Only the sigil + keeper name; no meta span child
    const spans = el.querySelectorAll('span[aria-hidden="true"]')
    // 1 keeper-name span, no meta span
    expect(spans.length).toBe(1)
  })

  it('non-interactive row omits tabindex', () => {
    const el = mount({ keeperId: 'a' })
    expect(el.getAttribute('tabindex')).toBeNull()
  })

  it('interactive row sets tabindex=0 and fires onActivate on click', () => {
    const onActivate = vi.fn()
    render(
      html`<${SidebarRow} keeperId="a" onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    expect(el.getAttribute('tabindex')).toBe('0')
    el.click()
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('Enter key activates an interactive row', () => {
    const onActivate = vi.fn()
    render(
      html`<${SidebarRow} keeperId="a" onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('Space key activates an interactive row', () => {
    const onActivate = vi.fn()
    render(
      html`<${SidebarRow} keeperId="a" onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('selected=true emits aria-current="true"', () => {
    const el = mount({ keeperId: 'a', selected: true })
    expect(el.getAttribute('aria-current')).toBe('true')
  })

  it('selected=false omits aria-current', () => {
    const el = mount({ keeperId: 'a' })
    expect(el.getAttribute('aria-current')).toBeNull()
  })

  it('idle status dims the row visually', () => {
    const el = mount({ keeperId: 'a', status: 'idle' })
    expect(parseFloat(el.style.opacity)).toBeLessThan(1)
  })

  it('stalled status also dims', () => {
    const el = mount({ keeperId: 'a', status: 'stalled' })
    expect(parseFloat(el.style.opacity)).toBeLessThan(1)
  })

  it('running status renders at full opacity', () => {
    const el = mount({ keeperId: 'a', status: 'running' })
    expect(el.style.opacity === '' || el.style.opacity === '1').toBe(true)
  })
})
