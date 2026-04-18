// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { IdPill, idPillClasses } from './id-pill'

describe('idPillClasses (pure)', () => {
  it('default (no mono, no extra) carries shape + accent tone', () => {
    const cls = idPillClasses()
    for (const token of [
      'inline-flex',
      'items-center',
      'text-3xs',
      'font-medium',
      'py-1',
      'px-2.5',
      'rounded',
      'whitespace-nowrap',
      'shadow-sm',
      'border',
      'border-accent/20',
      'bg-[var(--accent-10)]',
      'text-accent',
    ]) {
      expect(cls).toContain(token)
    }
  })

  it('mono=true appends font-mono, keeps font-medium (Tailwind composes weight + family)', () => {
    const cls = idPillClasses(true)
    expect(cls).toContain('font-mono')
    expect(cls).toContain('font-medium')
  })

  it('mono=false (default) omits font-mono', () => {
    expect(idPillClasses(false)).not.toContain('font-mono')
  })

  it('extra class appended (caller composition — hover states, margin)', () => {
    const cls = idPillClasses(false, 'group-hover:bg-accent/20 transition-colors')
    expect(cls).toContain('group-hover:bg-accent/20')
    expect(cls).toContain('transition-colors')
  })

  it('empty extra leaves the string tight (no trailing space)', () => {
    expect(idPillClasses(false, '')).not.toMatch(/\s$/)
    expect(idPillClasses(false, undefined)).not.toMatch(/\s$/)
  })

  it('shape tokens present regardless of mono flag (regression guard)', () => {
    for (const mono of [true, false]) {
      const cls = idPillClasses(mono)
      for (const token of ['rounded', 'text-3xs', 'px-2.5', 'py-1', 'text-accent']) {
        expect(cls).toContain(token)
      }
    }
  })
})

describe('IdPill component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders <span data-id-pill> with children verbatim', () => {
    render(html`<${IdPill}>task-42<//>`, container)
    const el = container.querySelector('[data-id-pill]')!
    expect(el.tagName).toBe('SPAN')
    expect(el.textContent).toBe('task-42')
  })

  it('data-id-pill-mono reflects mono prop (default false)', () => {
    render(html`<${IdPill}>plain<//>`, container)
    expect(container.querySelector('[data-id-pill]')!.getAttribute('data-id-pill-mono')).toBe('false')

    render(null, container)
    render(html`<${IdPill} mono=${true}>abc123def<//>`, container)
    expect(container.querySelector('[data-id-pill]')!.getAttribute('data-id-pill-mono')).toBe('true')
  })

  it('title renders as HTML title attribute', () => {
    render(html`<${IdPill} title="full tooltip">short<//>`, container)
    expect(container.querySelector('[data-id-pill]')!.getAttribute('title')).toBe('full tooltip')
  })

  it('testId renders as data-testid', () => {
    render(html`<${IdPill} testId="task-id-pill">t1<//>`, container)
    expect(container.querySelector('[data-testid="task-id-pill"]')).toBeTruthy()
  })

  it('class prop composes into the class attribute (hover state pass-through)', () => {
    render(
      html`<${IdPill} class="group-hover:bg-accent/20 transition-colors">t1<//>`,
      container,
    )
    const cls = container.querySelector('[data-id-pill]')!.getAttribute('class') ?? ''
    expect(cls).toContain('group-hover:bg-accent/20')
    expect(cls).toContain('transition-colors')
    expect(cls).toContain('rounded')
  })
})
