// @vitest-environment happy-dom
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_COMPACTIONS,
  DEFAULT_MEMORY_KEEPERS,
  KEEPER_MEMORY,
  MemoryInspector,
  memAggregate,
  memComposition,
  memFmtTok,
  type MemoryKeeper,
} from './memory-inspector'

afterEach(() => cleanup())

// masc-improver: ctx 0.86, has pinned facts, store entries, recall timeline,
// and a compaction record — exercises every section in the one-keeper view.
const improver: MemoryKeeper = DEFAULT_MEMORY_KEEPERS.find(k => k.id === 'masc-improver')!

function renderInspector(keeper: MemoryKeeper = improver, onClose = vi.fn()) {
  return render(html`<${MemoryInspector} keeper=${keeper} onClose=${onClose} />`)
}

describe('MemoryInspector — one-keeper scope', () => {
  it('renders the drawer shell scoped to the active keeper', () => {
    const { container } = renderInspector()
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.querySelector('.mem-drawer')).toBeTruthy()
    // header title + the active keeper id
    expect(container.querySelector('.turn-hd h3')?.textContent).toContain('Keeper 메모리')
    expect(container.querySelector('.tid')?.textContent).toBe('masc-improver')
  })

  it('renders the context-composition bar and a legend derived from live ctx tokens', () => {
    const { container } = renderInspector()
    const bar = container.querySelector('.mem-bar')
    expect(bar).toBeTruthy()
    // memComposition filters out zero-token parts; masc-improver has 5 parts.
    const comp = memComposition(improver)
    expect(comp.parts.length).toBeGreaterThan(0)
    expect(bar!.querySelectorAll('span').length).toBe(comp.parts.length)
    // legend rows mirror the parts
    expect(container.querySelectorAll('.mem-leg').length).toBe(comp.parts.length)
    // 86% header readout (Math.round(0.86 * 100))
    expect(container.querySelector('.mem-compo-sub')?.textContent).toContain('86%')
  })

  it('renders pinned facts with their count and operator/auto provenance', () => {
    const { container } = renderInspector()
    const pinHeads = [...container.querySelectorAll('.turn-sec h4')].map(h => h.textContent ?? '')
    expect(pinHeads.some(t => t.startsWith('핀 고정 사실'))).toBe(true)
    const pins = container.querySelectorAll('.mem-pin')
    expect(pins.length).toBe(KEEPER_MEMORY['masc-improver']!.pinned.length)
    // first pinned fact text is rendered verbatim
    expect(container.textContent).toContain('retention 정의: D0 = 가입일, 첫 세션 기준')
  })

  it('renders the salience store with one row per entry', () => {
    const { container } = renderInspector()
    const rows = container.querySelectorAll('.mem-store-row')
    expect(rows.length).toBe(KEEPER_MEMORY['masc-improver']!.store.length)
    // salience meter present on each row
    expect(container.querySelectorAll('.mem-store-row .mem-sal').length).toBe(rows.length)
  })

  it('filters the store by kind when a kind filter is clicked', () => {
    const { container } = renderInspector()
    const allRows = container.querySelectorAll('.mem-store-row').length
    // masc-improver has 5 distinct kinds, so filter buttons render.
    const declButtons = [...container.querySelectorAll('.mem-filter')]
    const decisionBtn = declButtons.find(b => (b.textContent ?? '').includes('결정'))
    expect(decisionBtn).toBeTruthy()
    fireEvent.click(decisionBtn!)
    const afterRows = container.querySelectorAll('.mem-store-row').length
    expect(afterRows).toBeLessThan(allRows)
    expect(afterRows).toBe(1) // exactly one 'decision' entry in the fixture
  })

  it('renders the recall timeline rows', () => {
    const { container } = renderInspector()
    const tlRows = container.querySelectorAll('.mem-tl-row')
    expect(tlRows.length).toBe(KEEPER_MEMORY['masc-improver']!.recall.length)
    // a compaction op row carries a negative token delta rendered with the minus glyph
    expect(container.querySelector('.mem-tl-tok.neg')?.textContent).toContain('−')
  })

  it('renders the compaction diff with kept / summarized / dropped columns', () => {
    const { container } = renderInspector()
    expect(container.querySelector('.cmp-diff')).toBeTruthy()
    expect(container.querySelector('.cmp-col.kept')).toBeTruthy()
    expect(container.querySelector('.cmp-col.summ')).toBeTruthy()
    expect(container.querySelector('.cmp-col.drop')).toBeTruthy()
    const cmp = DEFAULT_COMPACTIONS['masc-improver']![0]!
    expect(container.querySelector('.cmp-trigger')?.textContent).toContain(cmp.trigger)
  })

  it('shows the empty-state when a keeper has no compaction history', () => {
    // sangsu has store/pins but no DEFAULT_COMPACTIONS entry.
    const sangsu = DEFAULT_MEMORY_KEEPERS.find(k => k.id === 'sangsu')!
    const { container } = renderInspector(sangsu)
    expect(container.textContent).toContain('컴팩션 이력 없음')
  })
})

describe('MemoryInspector — scope toggle', () => {
  it('switches from one-keeper to the aggregate (전체) view', () => {
    const { container } = renderInspector()
    // one-keeper view first: a single composition bar, no aggregate table.
    expect(container.querySelector('.mem-table')).toBeFalsy()
    const allBtn = [...container.querySelectorAll('.mem-scope button')].find(
      b => b.textContent === '전체',
    )
    expect(allBtn).toBeTruthy()
    fireEvent.click(allBtn!)
    // aggregate view: keeper table + stats + kind distribution appear.
    expect(container.querySelector('.mem-table')).toBeTruthy()
    expect(container.querySelectorAll('.mem-stat').length).toBe(4)
    expect(container.querySelector('.tid')?.textContent).toBe('전체 keeper')
    // one table row per keeper in the roster.
    expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length).toBe(
      DEFAULT_MEMORY_KEEPERS.length,
    )
  })

  it('drills back into a single keeper when an aggregate row is clicked', () => {
    const { container } = renderInspector()
    fireEvent.click(
      [...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!,
    )
    const nickRow = [...container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)')].find(
      r => (r.textContent ?? '').includes('nick0cave'),
    )
    expect(nickRow).toBeTruthy()
    fireEvent.click(nickRow!)
    // back to one-keeper scope, now showing the picked keeper.
    expect(container.querySelector('.tid')?.textContent).toBe('nick0cave')
    expect(container.querySelector('.mem-table')).toBeFalsy()
  })
})

describe('MemoryInspector — close behaviour', () => {
  it('invokes onClose on overlay click and on the ✕ button', () => {
    const onClose = vi.fn()
    const { container } = renderInspector(improver, onClose)
    fireEvent.click(container.querySelector('.turn-close')!)
    expect(onClose).toHaveBeenCalledTimes(1)
    fireEvent.click(container.querySelector('.turn-overlay')!)
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('does not close when the drawer body itself is clicked (stopPropagation)', () => {
    const onClose = vi.fn()
    const { container } = renderInspector(improver, onClose)
    fireEvent.click(container.querySelector('.mem-drawer')!)
    expect(onClose).not.toHaveBeenCalled()
  })

  it('closes on Escape keydown', () => {
    const onClose = vi.fn()
    renderInspector(improver, onClose)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('memory model helpers', () => {
  it('memFmtTok abbreviates thousands and prefixes negatives with the minus glyph', () => {
    expect(memFmtTok(120)).toBe('120')
    expect(memFmtTok(1840)).toBe('1.8k')
    expect(memFmtTok(-110600)).toBe('−110.6k')
  })

  it('memComposition returns no parts for a stopped (ctx 0) keeper', () => {
    const drifter = DEFAULT_MEMORY_KEEPERS.find(k => k.id === 'drifter')!
    const comp = memComposition(drifter)
    expect(comp.total).toBe(0)
    expect(comp.parts).toEqual([])
  })

  it('memAggregate sums pins/store across keepers and caps topFacts at 6', () => {
    const agg = memAggregate(DEFAULT_MEMORY_KEEPERS)
    expect(agg.keeperCount).toBe(DEFAULT_MEMORY_KEEPERS.length)
    const expectedStore = DEFAULT_MEMORY_KEEPERS.reduce(
      (n, k) => n + (KEEPER_MEMORY[k.id]?.store.length ?? 0),
      0,
    )
    expect(agg.store).toBe(expectedStore)
    expect(agg.topFacts.length).toBeLessThanOrEqual(6)
    // topFacts are sorted by descending salience.
    for (let i = 1; i < agg.topFacts.length; i++) {
      expect(agg.topFacts[i - 1]!.salience).toBeGreaterThanOrEqual(agg.topFacts[i]!.salience)
    }
  })
})
