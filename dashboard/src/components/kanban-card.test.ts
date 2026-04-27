// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KanbanCard, kanbanCardAriaLabel, type KanbanCardProps } from './kanban-card'

describe('kanbanCardAriaLabel (pure)', () => {
  it('composes id · title · keeper for the minimal case', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-101',
        title: 'Auth refactor',
        keeperId: 'nick0cave',
      }),
    ).toBe('PK-101 · Auth refactor · nick0cave')
  })

  it('appends " · <kind>" when kind is non-queued', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-1',
        title: 't',
        keeperId: 'a',
        kind: 'running',
      }),
    ).toBe('PK-1 · t · a · running')
  })

  it('omits kind word when kind is "queued" (default state)', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-1',
        title: 't',
        keeperId: 'a',
        kind: 'queued',
      }),
    ).toBe('PK-1 · t · a')
  })

  it('appends " · <time>" when given', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-1',
        title: 't',
        keeperId: 'a',
        time: '2m',
      }),
    ).toBe('PK-1 · t · a · 2m')
  })

  it('combines kind + time in canonical order', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-9',
        title: 'Fix CI',
        keeperId: 'qa-king',
        kind: 'fail',
        time: '13:42',
      }),
    ).toBe('PK-9 · Fix CI · qa-king · fail · 13:42')
  })

  it('caller-supplied ariaLabel wins over composition', () => {
    expect(
      kanbanCardAriaLabel({
        id: 'PK-1',
        title: 't',
        keeperId: 'a',
        ariaLabel: 'Custom announcement',
      }),
    ).toBe('Custom announcement')
  })
})

describe('KanbanCard component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(props: KanbanCardProps): HTMLElement {
    render(html`<${KanbanCard} ...${props} />`, container)
    return container.querySelector('[role="listitem"]') as HTMLElement
  }

  it('renders role=listitem with composed aria-label', () => {
    const el = mount({
      id: 'PK-101',
      title: 'Auth refactor',
      keeperId: 'nick0cave',
    })
    expect(el).toBeTruthy()
    expect(el.getAttribute('role')).toBe('listitem')
    expect(el.getAttribute('aria-label')).toBe('PK-101 · Auth refactor · nick0cave')
  })

  it('renders id, title, keeper id text', () => {
    const el = mount({
      id: 'PK-101',
      title: 'Auth refactor',
      keeperId: 'nick0cave',
    })
    const txt = el.textContent ?? ''
    expect(txt).toContain('PK-101')
    expect(txt).toContain('Auth refactor')
    expect(txt).toContain('nick0cave')
  })

  it('renders the embedded KeeperBadge sigil text', () => {
    const el = mount({
      id: 'PK-1',
      title: 't',
      keeperId: 'nick0cave',
    })
    // Registry-pinned sigil for nick0cave is "NK".
    expect(el.textContent).toContain('NK')
  })

  it('renders relative time when given', () => {
    const el = mount({
      id: 'PK-1',
      title: 't',
      keeperId: 'a',
      time: '2m',
    })
    expect(el.textContent).toContain('2m')
  })

  it('omits time chip when not given', () => {
    const el = mount({ id: 'PK-1', title: 't', keeperId: 'a' })
    // " · 2m" pattern absence
    expect(el.textContent).not.toContain('· 2m')
  })

  it('non-interactive card omits tabindex', () => {
    const el = mount({ id: 'PK-1', title: 't', keeperId: 'a' })
    expect(el.getAttribute('tabindex')).toBeNull()
  })

  it('interactive card sets tabindex=0 and fires onActivate on click', () => {
    const onActivate = vi.fn()
    render(
      html`<${KanbanCard} id="PK-1" title="t" keeperId="a" onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    expect(el.getAttribute('tabindex')).toBe('0')
    el.click()
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('Enter key activates an interactive card', () => {
    const onActivate = vi.fn()
    render(
      html`<${KanbanCard} id="PK-1" title="t" keeperId="a" onActivate=${onActivate} />`,
      container,
    )
    const el = container.querySelector('[role="listitem"]') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onActivate).toHaveBeenCalledTimes(1)
  })

  it('running kind paints brass left border', () => {
    const el = mount({
      id: 'PK-1',
      title: 't',
      keeperId: 'a',
      kind: 'running',
    })
    expect(el.style.borderLeft).toContain('var(--color-accent-brass)')
  })

  it('fail kind paints err-status left border', () => {
    const el = mount({
      id: 'PK-1',
      title: 't',
      keeperId: 'a',
      kind: 'fail',
    })
    // Status err token surfaces in the inline border-left style
    expect(el.style.borderLeft).toContain('var(--color-status-err)')
  })
})
