// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  StatusChip,
  statusChipClasses,
  isSemanticTone,
  keeperStateTone,
  summarizeStatusChip,
} from './status-chip'

describe('isSemanticTone (pure)', () => {
  it('accepts the 8 enum members', () => {
    for (const tone of ['ok', 'warn', 'bad', 'info', 'neutral', 'paused', 'select', ''] as const) {
      expect(isSemanticTone(tone)).toBe(true)
    }
  })

  it('rejects raw Tailwind class strings (they pass through as extras)', () => {
    expect(isSemanticTone('bg-[var(--color-status-ok)]')).toBe(false)
    expect(isSemanticTone('text-accent-fg')).toBe(false)
  })
})

describe('keeperStateTone (pure)', () => {
  it('maps the 12 keeper FSM states per Anyang Sleepers spec', () => {
    expect(keeperStateTone('running')).toBe('ok')
    expect(keeperStateTone('compacting')).toBe('info')
    expect(keeperStateTone('handing_off')).toBe('info')
    expect(keeperStateTone('draining')).toBe('info')
    expect(keeperStateTone('failing')).toBe('warn')
    expect(keeperStateTone('overflowed')).toBe('warn')
    expect(keeperStateTone('restarting')).toBe('warn')
    expect(keeperStateTone('paused')).toBe('paused')
    expect(keeperStateTone('crashed')).toBe('bad')
    expect(keeperStateTone('dead')).toBe('bad')
    expect(keeperStateTone('stopped')).toBe('neutral')
    expect(keeperStateTone('offline')).toBe('neutral')
  })

  it('unknown states fall through to neutral rather than throwing', () => {
    expect(keeperStateTone('some_future_state')).toBe('neutral')
    expect(keeperStateTone('')).toBe('neutral')
  })

  it('also accepts dashboard-layer state names (KeeperLifecycleState + agent status)', () => {
    // types/core.ts KeeperLifecycleState
    expect(keeperStateTone('active')).toBe('ok')
    expect(keeperStateTone('preparing')).toBe('info')
    expect(keeperStateTone('handoff-imminent')).toBe('info')
    expect(keeperStateTone('idle')).toBe('neutral')
    expect(keeperStateTone('unbooted')).toBe('neutral')
    // agent.status union
    expect(keeperStateTone('busy')).toBe('warn')
    expect(keeperStateTone('listening')).toBe('info')
    expect(keeperStateTone('inactive')).toBe('neutral')
  })
})

describe('statusChipClasses (pure)', () => {
  it('default (no tone) uses neutral mapping + base tokens', () => {
    const cls = statusChipClasses()
    expect(cls).toContain('inline-flex')
    expect(cls).toContain('rounded-[var(--r-0)]')
    expect(cls).toContain('border')
    expect(cls).toContain('px-2')
    expect(cls).toContain('py-0.5')
    expect(cls).toContain('text-[11px]')
    expect(cls).toContain('uppercase')
    expect(cls).toContain('tracking-[0.05em]')
    // neutral fallback
    expect(cls).toContain('text-text-tertiary')
  })

  it("semantic 'ok' maps to ok CSS-var palette", () => {
    const cls = statusChipClasses('ok')
    expect(cls).toContain('text-success')
    expect(cls).toContain('bg-success/10')
  })

  it("semantic 'bad' maps to bad palette (text-destructive)", () => {
    const cls = statusChipClasses('bad')
    expect(cls).toContain('text-destructive')
  })

  it('raw Tailwind class string passes through verbatim', () => {
    const cls = statusChipClasses('bg-[var(--color-status-ok)]')
    // Raw tone gets appended; no semantic-palette leakage.
    expect(cls).toContain('bg-[var(--color-status-ok)]')
    expect(cls).not.toContain('text-success') // not expanded
  })

  it('extra class appended (caller composition)', () => {
    expect(statusChipClasses('warn', 'shrink-0 ml-2')).toContain('shrink-0 ml-2')
  })

  it('empty extra leaves the string tight (no trailing space)', () => {
    expect(statusChipClasses('ok', '')).not.toMatch(/\s$/)
    expect(statusChipClasses('ok', undefined)).not.toMatch(/\s$/)
  })

  it('base shape tokens present for every tone (regression guard, uppercase=true default)', () => {
    for (const tone of ['ok', 'warn', 'bad', 'info', 'neutral', '', 'bg-[var(--color-status-ok)]']) {
      const cls = statusChipClasses(tone)
      for (const token of ['rounded-[var(--r-0)]', 'text-[11px]', 'uppercase', 'tracking-[0.05em]']) {
        expect(cls).toContain(token)
      }
    }
  })
})

describe('statusChipClasses uppercase flag', () => {
  it('uppercase=false drops uppercase + tracking-[0.05em] (plain pill)', () => {
    const cls = statusChipClasses('neutral', undefined, false)
    expect(cls).not.toContain('uppercase')
    expect(cls).not.toContain('tracking-[0.05em]')
    // shape + tone still present
    expect(cls).toContain('rounded-[var(--r-0)]')
    expect(cls).toContain('text-[11px]')
    expect(cls).toContain('text-text-tertiary')
  })

  it('uppercase=true (explicit) matches the default', () => {
    expect(statusChipClasses('ok', undefined, true)).toBe(statusChipClasses('ok'))
  })

  it('shape tokens always present regardless of uppercase flag', () => {
    for (const uppercase of [true, false]) {
      const cls = statusChipClasses('warn', undefined, uppercase)
      for (const token of ['inline-flex', 'rounded-[var(--r-0)]', 'border', 'px-2', 'py-0.5', 'text-[11px]']) {
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
    expect(el.getAttribute('data-status-chip-content-source')).toBe('children')
    expect(el.getAttribute('data-status-chip-is-semantic-tone')).toBe('true')
  })

  it('data-status-chip-tone reflects tone prop', () => {
    render(html`<${StatusChip} tone="warn">heads up<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-tone')).toBe('warn')
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-is-semantic-tone')).toBe('true')
  })

  it('raw tone strings reflect non-semantic metadata', () => {
    render(html`<${StatusChip} tone="bg-[var(--accent-12)]">custom<//>`, container)
    const el = container.querySelector('[data-status-chip]')!
    expect(el.getAttribute('data-status-chip-tone')).toBe('bg-[var(--accent-12)]')
    expect(el.getAttribute('data-status-chip-is-semantic-tone')).toBe('false')
  })

  it('testId renders as data-testid', () => {
    render(html`<${StatusChip} class="ml-2" testId="approve-chip">ok<//>`, container)
    const el = container.querySelector('[data-testid="approve-chip"]')!
    expect(el).toBeTruthy()
    expect(el.getAttribute('data-status-chip-has-custom-class')).toBe('true')
    expect(el.getAttribute('data-status-chip-has-test-id')).toBe('true')
    expect(el.getAttribute('data-status-chip-class-length')).toBe('4')
    expect(el.getAttribute('data-status-chip-test-id-length')).toBe('12')
  })

  it('uppercase prop reflects on data-status-chip-uppercase (default true)', () => {
    render(html`<${StatusChip}>ok<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-uppercase')).toBe('true')

    render(null, container)
    render(html`<${StatusChip} uppercase=${false} tone="neutral">path.kind<//>`, container)
    expect(container.querySelector('[data-status-chip]')!.getAttribute('data-status-chip-uppercase')).toBe('false')
  })

  it('summarizes default status chip state', () => {
    expect(summarizeStatusChip({})).toEqual({
      tone: '',
      isSemanticTone: true,
      contentSource: 'empty',
      uppercase: true,
      hasCustomClass: false,
      hasTestId: false,
      classNameLength: 0,
      testIdLength: 0,
    })
  })

  it('summarizes raw-tone children status chip state', () => {
    expect(summarizeStatusChip({
      children: 'custom',
      tone: 'bg-[var(--accent-12)]',
      className: 'ml-2',
      uppercase: false,
      testId: 'custom-chip',
    })).toEqual({
      tone: 'bg-[var(--accent-12)]',
      isSemanticTone: false,
      contentSource: 'children',
      uppercase: false,
      hasCustomClass: true,
      hasTestId: true,
      classNameLength: 4,
      testIdLength: 11,
    })
  })
})
