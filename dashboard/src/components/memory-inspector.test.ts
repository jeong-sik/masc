// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_MEMORY_KEEPERS,
  MemoryInspector,
  factCategoryMeta,
  memCompositionFromBlocks,
  memFmtBytes,
  memFmtTok,
  promptBlockMeta,
  type MemoryKeeper,
} from './memory-inspector'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

// A turn-records payload exercising the two real-data sections (composition,
// facts), the episode-backed 압축 section, and read_errors. The unbacked
// sections (핀 / 회상) render disclosures regardless of payload.
function turnRecordsPayload() {
  return {
    keeper: 'masc-improver',
    count: 1,
    source: 'turn_record',
    memory_os: {
      schema: 'keeper.memory_os.recall_observability.v1',
      keeper: 'masc-improver',
      source: 'memory_os_files',
      producer: 'keeper_librarian',
      facts_store: '.masc/config/keepers/masc-improver.facts.jsonl',
      episodes_store: '.masc/config/keepers/masc-improver/episodes',
      recall_enabled: true,
      now: 1_790_000_000,
      now_iso: '2026-09-21T00:00:00Z',
      read_errors: [{ scope: 'facts', error: 'one malformed row skipped' }],
      episodes: {
        tail_limit: 12,
        shown: 1,
        current: 1,
        expired: 0,
        terminal_markers: 1,
        items: [
          {
            trace_id: 'trace-ep1',
            generation: 3,
            created_at: 1_789_900_000,
            created_at_iso: '2026-09-20T...Z',
            valid_until: null,
            valid_until_iso: null,
            current: true,
            terminal_marker: 'handoff_complete',
            claim_count: 4,
            summary: '리텐션 코호트 정의를 정리하고 amplitude 쿼리를 표로 캐시함.',
          },
        ],
      },
      facts: {
        tail_limit: 256,
        shown: 2,
        current: 1,
        expired: 1,
        items: [
          {
            claim: 'retention D0 = 가입일, 첫 세션 기준',
            category: 'constraint',
            source: { trace_id: 'trace-a', turn: 4, tool_call_id: null },
            first_seen: 1_789_000_000,
            first_seen_iso: '2026-09-09T...Z',
            reference_time: 1_789_500_000,
            valid_until: null,
            valid_until_iso: null,
            last_verified_at: 1_789_500_000,
            current: true,
            claim_kind: 'durable_knowledge',
            external_ref: { kind: 'pr', id: '22198' },
          },
          {
            claim: 'amplitude 캐시는 만료됨',
            category: 'Speculation', // out-of-vocabulary → Unknown chip
            source: { trace_id: 'trace-b', turn: 5 },
            first_seen: 1_789_100_000,
            first_seen_iso: '2026-09-09T...Z',
            reference_time: 1_789_100_000,
            valid_until: 1_789_200_000,
            valid_until_iso: '2026-09-09T...Z',
            last_verified_at: null,
            current: false,
          },
        ],
      },
    },
    user_model: null,
    entries: [
      {
        record: {
          keeper: 'masc-improver',
          trace_id: 'trace-a',
          absolute_turn: 7,
          ts: 1_789_999_000,
          runtime_profile: 'local',
          blocks: [
            { block: 'persona', bytes: 1200, digest: 'aaaa1111bbbb' },
            { block: 'memory_os_recall', bytes: 800, digest: 'cccc2222dddd' },
            { block: 'dynamic_context', bytes: 400, digest: 'eeee3333ffff' },
            { block: 'zero_block', bytes: 0, digest: '000000000000' },
          ],
          execution_ids: [],
          input_tokens: 3500,
          context_window: 200000,
        },
        diff_vs_prev: null,
      },
    ],
  }
}

function stubFetch(payload: unknown = turnRecordsPayload()) {
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(
    new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } }),
  ))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

const improver: MemoryKeeper = { id: 'masc-improver', ctx: 0.86, status: 'run' }

function renderInspector(keeper: MemoryKeeper = improver, onClose = vi.fn()) {
  return render(html`<${MemoryInspector} keeper=${keeper} onClose=${onClose} />`)
}

describe('MemoryInspector — one-keeper scope (real data)', () => {
  it('fetches turn-records for the keeper and renders the drawer shell', async () => {
    const fetchMock = stubFetch()
    const { container } = renderInspector()
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.querySelector('.mem-drawer')).toBeTruthy()
    expect(container.querySelector('.turn-hd h3')?.textContent).toContain('Keeper 메모리')
    expect(container.querySelector('.tid')?.textContent).toBe('masc-improver')
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/v1/keepers/masc-improver/turn-records?limit=24')
  })

  it('builds the composition bar from real prompt-block bytes (zero blocks dropped)', async () => {
    stubFetch()
    const { container } = renderInspector()
    const bar = await waitFor(() => {
      const b = container.querySelector('.mem-bar')
      expect(b).toBeTruthy()
      return b!
    })
    // 4 blocks in payload, 1 has 0 bytes → 3 segments + 3 legend rows.
    expect(bar.querySelectorAll('span').length).toBe(3)
    expect(container.querySelectorAll('.mem-leg').length).toBe(3)
    // total bytes = 1200+800+400 = 2400, shown as KB; token readout from input_tokens.
    expect(container.querySelector('.mem-compo-tot')?.textContent).toBe('2.3KB')
    expect(container.querySelector('.mem-compo-sub')?.textContent).toContain('3.5k tok')
    // block labels come from the Prompt_block_id mirror, not raw tokens.
    expect(container.textContent).toContain('메모리 회상')
    expect(container.textContent).toContain('동적 컨텍스트')
  })

  it('renders one store row per real fact with typed category chips and Unknown absorption', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelectorAll('.mem-store-row').length).toBeGreaterThan(0))
    // 2 fact items + 1 episode row all use .mem-store-row; assert facts by claim text.
    expect(container.textContent).toContain('retention D0 = 가입일, 첫 세션 기준')
    expect(container.textContent).toContain('제약') // constraint chip label
    // out-of-vocabulary category surfaces its raw label, not a fabricated kind.
    expect(container.textContent).toContain('Speculation')
    // external_ref rendered
    expect(container.textContent).toContain('pr 22198')
    // NO salience meter — the deleted score model must not reappear.
    expect(container.querySelector('.mem-sal')).toBeFalsy()
  })

  it('surfaces read_errors and renders honest disclosures for the unbacked sections', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    // read_errors visible (no silent failure)
    expect(container.querySelector('.mem-read-error')?.textContent).toContain('one malformed row skipped')
    // pins → Phase 2 disclosure, timeline → Phase 3 disclosure (no fabricated rows)
    const disclosures = [...container.querySelectorAll('.mem-disclosure')].map(d => d.textContent ?? '')
    expect(disclosures.some(t => t.includes('Phase 2'))).toBe(true)
    expect(disclosures.some(t => t.includes('Phase 3'))).toBe(true)
    // no prototype fixture leakage
    expect(container.querySelector('.mem-pin')).toBeFalsy()
    expect(container.querySelector('.mem-tl-row')).toBeFalsy()
  })

  it('renders the compaction section from real episodes (summary + terminal marker)', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.textContent).toContain('리텐션 코호트 정의'))
    expect(container.textContent).toContain('terminal=handoff_complete')
    expect(container.textContent).toContain('4 claims')
  })

  it('shows an explicit empty state when memory_os is absent (no fabrication)', async () => {
    stubFetch({ keeper: 'ghost', count: 0, source: 'turn_record', memory_os: null, user_model: null, entries: [] })
    const { container } = renderInspector({ id: 'ghost', ctx: 0, status: 'off' })
    await waitFor(() => expect(container.textContent).toContain('memory-os 소스 없음'))
    expect(container.querySelector('.mem-bar')).toBeFalsy()
  })
})

describe('MemoryInspector — scope toggle', () => {
  it('switches to the aggregate (전체) view showing the real roster + a deferral note', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    const allBtn = [...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')
    expect(allBtn).toBeTruthy()
    fireEvent.click(allBtn!)
    expect(container.querySelector('.tid')?.textContent).toBe('전체 keeper')
    // roster table = one row per default keeper (ids + status are real)
    expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length).toBe(DEFAULT_MEMORY_KEEPERS.length)
    // aggregate memory totals are deferred, disclosed — not fabricated
    expect([...container.querySelectorAll('.mem-disclosure')].some(d => (d.textContent ?? '').includes('추후 연결'))).toBe(true)
  })

  it('maps roster status to dot state run→ok / pause→idle / off→bad', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    const dotClassFor = (id: string): string | undefined => {
      const row = [...container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)')].find(r =>
        (r.querySelector('.mem-td-id .mono')?.textContent ?? '') === id)
      return row?.querySelector('.mem-dot')?.className
    }
    expect(dotClassFor('nick0cave')).toContain('ok')
    expect(dotClassFor('qa-king')).toContain('idle')
    expect(dotClassFor('drifter')).toContain('bad')
  })
})

describe('MemoryInspector — close behaviour', () => {
  it('invokes onClose on overlay click and on the ✕ button', () => {
    stubFetch()
    const onClose = vi.fn()
    const { container } = renderInspector(improver, onClose)
    fireEvent.click(container.querySelector('.turn-close')!)
    expect(onClose).toHaveBeenCalledTimes(1)
    fireEvent.click(container.querySelector('.turn-overlay')!)
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('does not close when the drawer body itself is clicked (stopPropagation)', () => {
    stubFetch()
    const onClose = vi.fn()
    const { container } = renderInspector(improver, onClose)
    fireEvent.click(container.querySelector('.mem-drawer')!)
    expect(onClose).not.toHaveBeenCalled()
  })

  it('closes on Escape keydown', () => {
    stubFetch()
    const onClose = vi.fn()
    renderInspector(improver, onClose)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('memory view-model helpers', () => {
  it('memFmtTok abbreviates thousands and prefixes negatives with the minus glyph', () => {
    expect(memFmtTok(120)).toBe('120')
    expect(memFmtTok(1840)).toBe('1.8k')
    expect(memFmtTok(-110600)).toBe('−110.6k')
  })

  it('memFmtBytes scales B / KB / MB', () => {
    expect(memFmtBytes(500)).toBe('500B')
    expect(memFmtBytes(1536)).toBe('1.5KB')
    expect(memFmtBytes(2 * 1024 * 1024)).toBe('2.0MB')
  })

  it('memCompositionFromBlocks sums real bytes and drops zero-byte blocks', () => {
    const comp = memCompositionFromBlocks([
      { block: 'persona', bytes: 1200, digest: 'x' },
      { block: 'memory_os_recall', bytes: 800, digest: 'y' },
      { block: 'empty', bytes: 0, digest: 'z' },
    ])
    expect(comp.totalBytes).toBe(2000)
    expect(comp.parts.map(p => p.key)).toEqual(['persona', 'memory_os_recall'])
    expect(comp.parts[0]?.lbl).toBe('페르소나')
  })

  it('promptBlockMeta maps known Prompt_block_id tokens and keeps unknown tokens raw', () => {
    expect(promptBlockMeta('user_model').lbl).toBe('사용자 모델')
    expect(promptBlockMeta('connected_surface').lbl).toBe('연결 표면')
    expect(promptBlockMeta('some_future_block').lbl).toBe('some_future_block')
  })

  it('factCategoryMeta covers every taxonomy arm and carries the raw Unknown label', () => {
    const tags = [
      'code_change', 'fact', 'preference', 'blocker', 'goal',
      'constraint', 'ephemeral', 'validated_approach', 'lesson',
    ] as const
    for (const tag of tags) {
      const meta = factCategoryMeta({ tag })
      expect(meta.lbl.length).toBeGreaterThan(0)
      expect(meta.glyph.length).toBeGreaterThan(0)
    }
    expect(factCategoryMeta({ tag: 'unknown', raw: 'Speculation' }).lbl).toBe('Speculation')
  })
})
