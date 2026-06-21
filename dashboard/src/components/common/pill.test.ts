// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Pill, pillClasses, isPillTone, summarizePill } from './pill'
import { statusChipClasses } from './status-chip'

describe('isPillTone (pure)', () => {
  it('accepts the 8 chip tones plus the volt accent', () => {
    for (const tone of ['neutral', 'ok', 'warn', 'bad', 'info', 'volt', 'paused', 'select', ''] as const) {
      expect(isPillTone(tone)).toBe(true)
    }
  })

  it('rejects raw Tailwind class strings (they pass through verbatim)', () => {
    expect(isPillTone('bg-[var(--color-status-ok)]')).toBe(false)
    expect(isPillTone('text-accent-fg')).toBe(false)
  })
})

describe('pillClasses (pure)', () => {
  it('default (no tone) uses neutral mapping + base shape', () => {
    const cls = pillClasses()
    for (const t of ['inline-flex', 'rounded-[var(--r-0)]', 'border', 'px-2', 'py-0.5', 'text-[11px]', 'uppercase', 'tracking-[0.05em]']) {
      expect(cls).toContain(t)
    }
    expect(cls).toContain('text-text-tertiary') // neutral fallback
  })

  it('maps each semantic tone to its palette', () => {
    expect(pillClasses('ok')).toContain('text-success')
    expect(pillClasses('ok')).toContain('bg-success/10')
    expect(pillClasses('warn')).toContain('text-warning')
    expect(pillClasses('bad')).toContain('text-destructive')
    expect(pillClasses('info')).toContain('text-brand')
    expect(pillClasses('paused')).toContain('text-[var(--paused)]')
    expect(pillClasses('select')).toContain('text-[var(--select)]')
  })

  it('volt maps to the --volt-* triple', () => {
    const cls = pillClasses('volt')
    expect(cls).toContain('text-[var(--volt-strong)]')
    expect(cls).toContain('border-[var(--volt-dim)]')
    expect(cls).toContain('bg-[var(--volt-wash)]')
  })

  it('raw Tailwind tone passes through without semantic expansion', () => {
    const cls = pillClasses('bg-[var(--color-status-ok)]')
    expect(cls).toContain('bg-[var(--color-status-ok)]')
    expect(cls).not.toContain('text-success')
  })

  it('uppercase=false drops uppercase + tracking, keeps shape + tone', () => {
    const cls = pillClasses('neutral', { uppercase: false })
    expect(cls).not.toContain('uppercase')
    expect(cls).not.toContain('tracking-[0.05em]')
    expect(cls).toContain('rounded-[var(--r-0)]')
    expect(cls).toContain('text-text-tertiary')
  })

  it('mono adds font-mono', () => {
    expect(pillClasses('ok', { mono: true })).toContain('font-mono')
    expect(pillClasses('ok')).not.toContain('font-mono')
  })

  it('soft strips the bg token but keeps border + text', () => {
    const cls = pillClasses('ok', { soft: true })
    expect(cls).not.toContain('bg-success/10')
    expect(cls).toContain('border-success/20')
    expect(cls).toContain('text-success')
  })

  it('extra appended; empty/undefined extra leaves no trailing space', () => {
    expect(pillClasses('warn', { extra: 'shrink-0 ml-2' })).toContain('shrink-0 ml-2')
    expect(pillClasses('ok', { extra: '' })).not.toMatch(/\s$/)
    expect(pillClasses('ok', { extra: undefined })).not.toMatch(/\s$/)
  })
})

// The convergence contract: StatusChip's class helper now delegates here, so
// the two MUST agree for every shape the old inline implementation produced.
describe('convergence: statusChipClasses === pillClasses', () => {
  const tones = ['', 'ok', 'warn', 'bad', 'info', 'neutral', 'paused', 'select', 'bg-[var(--accent-12)]']
  it('matches for every tone (uppercase default)', () => {
    for (const tone of tones) {
      expect(statusChipClasses(tone)).toBe(pillClasses(tone, { uppercase: true }))
    }
  })
  it('matches with uppercase=false and with an extra class', () => {
    for (const tone of tones) {
      expect(statusChipClasses(tone, 'ml-2', false)).toBe(pillClasses(tone, { uppercase: false, extra: 'ml-2' }))
    }
  })
})

describe('summarizePill (pure)', () => {
  it('summarizes the default pill', () => {
    expect(summarizePill({})).toEqual({
      tone: 'neutral',
      isSemanticTone: true,
      uppercase: true,
      hasDot: false,
      contentSource: 'empty',
      hasCustomClass: false,
      hasTestId: false,
    })
  })

  it('summarizes a raw-tone pill with children + custom class', () => {
    expect(summarizePill({ tone: 'bg-[var(--x)]', children: 'hi', class: 'ml-2', dot: true, testId: 't' })).toEqual({
      tone: 'bg-[var(--x)]',
      isSemanticTone: false,
      uppercase: true,
      hasDot: true,
      contentSource: 'children',
      hasCustomClass: true,
      hasTestId: true,
    })
  })
})

describe('Pill component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders <span data-pill> with children and tone metadata', () => {
    render(html`<${Pill} tone="ok">running<//>`, container)
    const el = container.querySelector('[data-pill]')!
    expect(el.tagName).toBe('SPAN')
    expect(el.textContent).toBe('running')
    expect(el.getAttribute('data-pill-tone')).toBe('ok')
    expect(el.getAttribute('data-pill-semantic-tone')).toBe('true')
    expect(el.getAttribute('data-pill-content-source')).toBe('children')
  })

  it('raw tone marks non-semantic', () => {
    render(html`<${Pill} tone="bg-[var(--accent-12)]">x<//>`, container)
    expect(container.querySelector('[data-pill]')!.getAttribute('data-pill-semantic-tone')).toBe('false')
  })

  it('dot renders a leading pip and reflects data-pill-has-dot', () => {
    render(html`<${Pill} tone="ok" dot=${true}>live<//>`, container)
    const el = container.querySelector('[data-pill]')!
    expect(el.getAttribute('data-pill-has-dot')).toBe('true')
    expect(el.querySelector('span.bg-current')).toBeTruthy()
  })

  it('testId renders as data-testid', () => {
    render(html`<${Pill} testId="my-pill">x<//>`, container)
    expect(container.querySelector('[data-testid="my-pill"]')).toBeTruthy()
    expect(container.querySelector('[data-pill]')!.getAttribute('data-pill-has-test-id')).toBe('true')
  })

  it('uppercase=false reflects on data-pill-uppercase', () => {
    render(html`<${Pill} uppercase=${false}>x<//>`, container)
    expect(container.querySelector('[data-pill]')!.getAttribute('data-pill-uppercase')).toBe('false')
  })
})
