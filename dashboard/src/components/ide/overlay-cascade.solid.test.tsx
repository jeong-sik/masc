/** @jsxImportSource solid-js */
// @vitest-environment happy-dom
//
// Unit + a11y tests for OverlayCascade (overlay-cascade.solid.tsx).
// Covers:
//   - formatCost / formatLatency / shortModel helpers (pure)
//   - OverlayCascade DOM structure (Solid render)
//   - Zero-hits empty state (mockup §3 requirement)
//   - Neutral runtime chip rendering
//   - Axe accessibility (RFC-0020 §, toggle keyboard accessibility)

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'solid-js/web'
import { axe, toHaveNoViolations } from 'jest-axe'
import {
  OverlayCascade,
  formatCost,
  formatLatency,
  shortModel,
  type CascadeLineHit,
} from './overlay-cascade.solid'

// Wire jest-axe into Vitest's expect for this Solid test suite
// (vitest.solid.config.ts has no setupFiles, so we extend locally).
expect.extend(toHaveNoViolations)

// ── Helpers ────────────────────────────────────────────────────────

let host: HTMLDivElement
let dispose: (() => void) | undefined

beforeEach(() => {
  host = document.createElement('div')
  document.body.appendChild(host)
})

afterEach(() => {
  dispose?.()
  dispose = undefined
  host.remove()
})

function mount(hits: ReadonlyArray<CascadeLineHit>, testId = 'cascade-overlay'): HTMLElement {
  dispose = render(
    () => <OverlayCascade hits={hits} testId={testId} />,
    host,
  )
  return host.querySelector(`[data-testid="${testId}"]`) as HTMLElement
}

// ── Pure helpers ───────────────────────────────────────────────────

describe('formatCost', () => {
  it('returns "—" for null', () => expect(formatCost(null)).toBe('—'))
  it('returns "$0" for zero', () => expect(formatCost(0)).toBe('$0'))
  it('returns "< $0.000001" for sub-micro amounts', () => expect(formatCost(0.0000001)).toBe('< $0.000001'))
  it('formats microdollar range as µ$', () => {
    expect(formatCost(0.000042)).toBe('42 µ$')
    expect(formatCost(0.0001)).toBe('100 µ$')
  })
  it('formats dollar range (trailing zeros stripped)', () => {
    expect(formatCost(0.0015)).toBe('$0.0015')
    expect(formatCost(1.5)).toBe('$1.5')
  })
})

describe('formatLatency', () => {
  it('returns "—" for null', () => expect(formatLatency(null)).toBe('—'))
  it('formats sub-second latency as ms', () => {
    expect(formatLatency(0)).toBe('0ms')
    expect(formatLatency(999)).toBe('999ms')
  })
  it('formats 1000+ ms as seconds', () => {
    expect(formatLatency(1000)).toBe('1.0s')
    expect(formatLatency(2500)).toBe('2.5s')
  })
})

describe('shortModel', () => {
  it('redacts concrete model names to the neutral runtime label', () => {
    expect(shortModel('claude-3-5-sonnet-20241022')).toBe('runtime')
    expect(shortModel('ollama/llama3.2')).toBe('runtime')
    expect(shortModel('gpt-4o-mini')).toBe('runtime')
  })
})

// ── OverlayCascade DOM ─────────────────────────────────────────────

const SAMPLE_HIT: CascadeLineHit = {
  line: 42,
  provider: 'anthropic',
  model: 'claude-3-5-sonnet-20241022',
  cost_usd: 0.000042,
  latency_ms: 1250,
}

describe('OverlayCascade', () => {
  it('renders a <ul> with role=list', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.tagName).toBe('UL')
    expect(el.getAttribute('role')).toBe('list')
  })

  it('emits aria-label with hit count', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.getAttribute('aria-label')).toContain('1 hit')
  })

  it('uses plural "hits" for count > 1', () => {
    const el = mount([SAMPLE_HIT, { ...SAMPLE_HIT, line: 43 }])
    expect(el.getAttribute('aria-label')).toContain('2 hits')
  })

  it('renders one <li> per hit', () => {
    const el = mount([SAMPLE_HIT, { ...SAMPLE_HIT, line: 43 }])
    expect(el.querySelectorAll('li').length).toBe(2)
  })

  // ── 0-hits empty state (mockup §3 raw hex 0 hits) ─────────────

  it('renders an empty <ul> with 0 hits (no visible chips)', () => {
    const el = mount([])
    expect(el.tagName).toBe('UL')
    expect(el.querySelectorAll('li').length).toBe(0)
    expect(el.getAttribute('aria-label')).toContain('0 hits')
  })

  // ── Line number ────────────────────────────────────────────────

  it('shows the line number in the first <li>', () => {
    const el = mount([SAMPLE_HIT])
    const li = el.querySelector('li')!
    expect(li.textContent).toContain('42')
  })

  // ── Runtime chip ───────────────────────────────────────────────

  it('includes neutral runtime chip text', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.textContent).toContain('runtime')
    expect(el.textContent).not.toContain('anthropic')
  })

  it('uses neutral styling for known provider input', () => {
    const el = mount([SAMPLE_HIT])
    const chip = el.querySelector('li > span:nth-child(2)') as HTMLElement | null
    const style = chip?.getAttribute('style') ?? ''
    expect(style).toContain('var(--color-border-default)')
    expect(style).not.toContain('--color-p-anthropic')
  })

  it('keeps neutral styling for unknown provider input', () => {
    const hit: CascadeLineHit = { ...SAMPLE_HIT, provider: 'unknown-llm' }
    const el = mount([hit])
    const chip = el.querySelector('li > span:nth-child(2)') as HTMLElement | null
    expect(chip?.getAttribute('style') ?? '').toContain('var(--color-border-default)')
    expect(el.textContent).not.toContain('unknown-llm')
  })

  // ── Model label ────────────────────────────────────────────────

  it('does not show model name', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.textContent).not.toContain('claude-3-5-sonnet')
    expect(el.textContent).not.toContain('20241022')
  })

  // ── Cost + latency ─────────────────────────────────────────────

  it('shows formatted cost', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.textContent).toContain('42 µ$')
  })

  it('shows formatted latency', () => {
    const el = mount([SAMPLE_HIT])
    expect(el.textContent).toContain('1.3s')
  })

  it('shows "—" for null cost', () => {
    const el = mount([{ ...SAMPLE_HIT, cost_usd: null }])
    expect(el.textContent).toContain('—')
  })

  it('shows "—" for null latency', () => {
    const el = mount([{ ...SAMPLE_HIT, latency_ms: null }])
    expect(el.textContent).toContain('—')
  })

  // ── a11y (RFC-0020 §, toggle keyboard accessibility) ──────────

  it('renders accessibly with hits', async () => {
    mount([SAMPLE_HIT])
    expect(await axe(host)).toHaveNoViolations()
  })

  it('renders accessibly with zero hits', async () => {
    mount([])
    expect(await axe(host)).toHaveNoViolations()
  })

  it('each <li> has a descriptive aria-label', () => {
    const el = mount([SAMPLE_HIT])
    const li = el.querySelector('li')!
    const label = li.getAttribute('aria-label') ?? ''
    expect(label).toContain('Line 42')
    expect(label).toContain('runtime')
    expect(label).not.toContain('anthropic')
    expect(label).not.toContain('claude-3-5-sonnet')
  })
})
