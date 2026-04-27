// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Kbd, kbdClasses } from './kbd'

describe('kbdClasses (pure)', () => {
  it('default size is md (shortcut-sheet row baseline)', () => {
    expect(kbdClasses()).toBe(kbdClasses('md'))
  })

  it('md variant: SPEC 16×16 chiclet + muted fg + 4px horizontal padding', () => {
    // SPEC primitives.css `.kbd`: min-width:16px height:16px padding:0 4px,
    // color: var(--color-fg-muted).
    const cls = kbdClasses('md')
    expect(cls).toContain('text-3xs')
    expect(cls).toContain('h-4')
    expect(cls).toContain('min-w-4')
    expect(cls).toContain('px-1')
    expect(cls).toContain('text-[var(--color-fg-muted)]')
  })

  it('sm variant: 10px text + tight padding (px-1 py-0) + dimmed fg', () => {
    // sm is a Tailwind-only tightening (SPEC defines md only) — same
    // chiclet visuals, no fixed dimensions, dimmed color for inline use.
    const cls = kbdClasses('sm')
    expect(cls).toContain('text-3xs')
    expect(cls).toContain('px-1')
    expect(cls).toContain('py-0')
    expect(cls).toContain('text-[var(--color-fg-disabled)]')
    expect(cls).not.toContain('h-4')
    expect(cls).not.toContain('min-w-4')
  })

  it('extra class is appended (caller composition)', () => {
    expect(kbdClasses('md', 'ml-2')).toContain('ml-2')
  })

  it('empty/undefined extra class leaves the string tight (no trailing space)', () => {
    expect(kbdClasses('md', '')).not.toMatch(/\s$/)
    expect(kbdClasses('md', undefined)).not.toMatch(/\s$/)
  })

  it('both variants share SPEC chiclet base (border-strong, bg-elevated, border-b-2 chiclet, rounded-xs)', () => {
    // Regression guard: drifting the chiclet base breaks visual
    // consistency across every call site the primitive unifies and
    // diverges from primitives.css `.kbd`.
    const md = kbdClasses('md')
    const sm = kbdClasses('sm')
    for (const token of [
      'inline-flex',
      'rounded-xs',
      'border-b-2',
      'font-mono',
      'border-[var(--color-border-strong)]',
      'bg-[var(--color-bg-elevated)]',
      'text-3xs',
    ]) {
      expect(md).toContain(token)
      expect(sm).toContain(token)
    }
  })
})

describe('Kbd component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a <kbd> element with children + data-kbd attribute', () => {
    render(html`<${Kbd}>⌘K<//>`, container)
    const el = container.querySelector('kbd[data-kbd]')!
    expect(el.tagName).toBe('KBD')
    expect(el.textContent).toBe('⌘K')
  })

  it('data-kbd-size reflects the size prop (default md)', () => {
    render(html`<${Kbd}>?<//>`, container)
    expect(container.querySelector('[data-kbd]')!.getAttribute('data-kbd-size')).toBe('md')

    render(null, container)
    render(html`<${Kbd} size="sm">?<//>`, container)
    expect(container.querySelector('[data-kbd]')!.getAttribute('data-kbd-size')).toBe('sm')
  })

  it('title attribute propagates (hover tooltip parity with raw <kbd>)', () => {
    render(html`<${Kbd} title="단축키 목록 (?)">?<//>`, container)
    expect(container.querySelector('[data-kbd]')!.getAttribute('title')).toBe('단축키 목록 (?)')
  })

  it('testId renders as data-testid', () => {
    render(html`<${Kbd} testId="help-kbd">?<//>`, container)
    expect(container.querySelector('[data-testid="help-kbd"]')).toBeTruthy()
  })

  it('multi-character key labels render verbatim (no chord parsing)', () => {
    // The primitive deliberately doesn't split "Ctrl+Shift+P" — callers
    // that want per-key pills compose multiple <Kbd> with separators.
    render(html`<${Kbd}>Ctrl+Shift+P<//>`, container)
    expect(container.querySelector('[data-kbd]')!.textContent).toBe('Ctrl+Shift+P')
  })
})
