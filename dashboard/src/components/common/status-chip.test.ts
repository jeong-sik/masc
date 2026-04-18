// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { StatusChip, statusChipClasses, isSemanticTone } from './status-chip'

describe('isSemanticTone (pure)', () => {
  it('accepts the 6 enum members', () => {
    for (const tone of ['ok', 'warn', 'bad', 'info', 'neutral', ''] as const) {
      expect(isSemanticTone(tone)).toBe(true)
    }
  })

  it('rejects raw Tailwind class strings (they pass through as extras)', () => {
    expect(isSemanticTone('bg-[var(--ok)]')).toBe(false)
    expect(isSemanticTone('text-accent')).toBe(false)
  })
})

describe('statusChipClasses (pure)', () => {
  it('default (no tone) uses neutral mapping + base tokens', () => {
    const cls = statusChipClasses()
    expect(cls).toContain('inline-flex')
    expect(cls).toContain('rounded-full')
    expect(cls).toContain('border')
    expect(cls).toContain('px-2')
    expect(cls).toContain('py-0.5')
    expect(cls).toContain('text-[10px]')
    expect(cls).toContain('uppercase')
    expect(cls).toContain('tracking-wider')
    // neutral fallback
    expect(cls).toContain('text-[var(--text-muted)]')
  })

  it("semantic 'ok' maps to ok CSS-var palette", () => {
    const cls = statusChipClasses('ok')
    expect(cls).toContain('text-[var(--ok)]')
    expect(cls).toContain('bg-[var(--ok-10)]')
  })

  it("semantic 'bad' maps to bad palette (text-[var(--bad-light)])", () => {
    const cls = statusChipClasses('bad')
    expect(cls).toContain('text-[var(--bad-light)]')
  })

  it('raw Tailwind class string passes through verbatim', () => {
    const cls = statusChipClasses('bg-[var(--ok)]')
    // Raw tone gets appended; no semantic-palette leakage.
    expect(cls).toContain('bg-[var(--ok)]')
    expect(cls).not.toContain('text-[var(--ok)]') // not expanded
  })

  it('extra class appended (caller composition)', () => {
    expect(statusChipClasses('warn', 'shrink-0 ml-2')).toContain('shrink-0 ml-2')
  })

  it('empty extra leaves the string tight (no trailing space)', () => {
    expect(statusChipClasses('ok', '')).not.toMatch(/\s$/)
    expect(statusChipClasses('ok', undefined)).not.toMatch(/\s$/)
  })

  it('base shape tokens present for every tone (regression guard, uppercase=true default)', () => {
    for (const tone of ['ok', 'warn', 'bad', 'info', 'neutral', '', 'bg-[var(--ok)]']) {
      const cls = statusChipClasses(tone)
      for (const token of ['rounded-full', 'text-[10px]', 'uppercase', 'tracking-wider']) {
        expect(cls).toContain(token)
      }
    }
  })
})

describe('statusChipClasses uppercase flag', () => {
  it('uppercase=false drops uppercase + tracking-wider (plain pill)', () => {
    const cls = statusChipClasses('neutral', undefined, false)
    expect(cls).not.toContain('uppercase')
    expect(cls).not.toContain('tracking-wider')
    // shape + tone still present
    expect(cls).toContain('rounded-full')
    expect(cls).toContain('text-[10px]')
    expect(cls).toContain('text-[var(--text-muted)]')
  })

  it('uppercase=true (explicit) matches the default', () => {
    expect(statusChipClasses('ok', undefined, true)).toBe(statusChipClasses('ok'))
  })

  it('shape tokens always present regardless of uppercase flag', () => {
    for (const uppercase of [true, false]) {
      const cls = statusChipClasses('warn', undefined, uppercase)
      for (const token of ['inline-flex', 'rounded-full', 'border', 'px-2', 'py-0.5', 'text-[10px]']) {
        expect(cls).toContain(token)
      }
    }
  })
})

describe('StatusChip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders <span data-status-chip> with children verbatim', () => {
    render(html`<${StatusChip}>approved<//>`, container)
    const el = container.querySelector('[data-status-chip]')!
    expect(el.tagName).toBe('SPAN')
    expect(el.textContent).toBe('approved')
  })

  it('label prop renders when children absent (legacy API)', () => {
    render(html`<${StatusChip} label="present" />`, container)
    expect(container.querySelector('[data-status-chip]')!.textContent).toBe('present')
  })

  it('children win over label when both are set', () => {
    render(html`<${StatusChip} label="legacy">actual<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.textContent).toBe('actual')
  })

  it('data-status-chip-tone reflects tone prop', () => {
    render(html`<${StatusChip} tone="warn">heads up<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-tone')).toBe('warn')
  })

  it('testId renders as data-testid', () => {
    render(html`<${StatusChip} testId="approve-chip">ok<//>`, container)
    expect(container.querySelector('[data-testid="approve-chip"]')).toBeTruthy()
  })

  it('uppercase prop reflects on data-status-chip-uppercase (default true)', () => {
    render(html`<${StatusChip}>ok<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-uppercase')).toBe('true')

    render(null, container)
    render(html`<${StatusChip} uppercase=${false} tone="neutral">path.kind<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-uppercase')).toBe('false')
  })
})
