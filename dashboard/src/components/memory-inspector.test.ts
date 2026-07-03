// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_MEMORY_KEEPERS,
  MemoryInspector,
  factCategoryMeta,
  factSelectionReason,
  factTtlLabel,
  latestEntryWithBlocks,
  memCompositionFromBlocks,
  memFmtBytes,
  memFmtTok,
  promptBlockMeta,
  recentMemoryRecallInjections,
  sortMemoryFactsForReview,
  type MemoryKeeper,
} from './memory-inspector'
import {
  MEMORY_OS_LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER,
  type MemoryOsFact,
  type TurnRecordRow,
} from '../api/dashboard'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

// A turn-records payload exercising the two real-data sections (composition,
// facts), the episode-backed 압축 section, recall-block timeline, and read_errors.
// The unbacked pin section renders a disclosure regardless of payload.
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
      selection_policy: {
        keeper_scope: 'masc-improver',
        shared_scope: '_shared',
        facts_source: 'Keeper_memory_os_io.read_facts_tail',
        shared_facts_source: 'Keeper_memory_os_io.read_facts_all',
        episodes_source: 'Keeper_memory_os_io.read_episodes_tail',
        dashboard_fact_tail_limit: 384,
        dashboard_episode_tail_limit: 12,
        recall_private_fact_limit: 8,
        recall_shared_fact_limit: 4,
        recall_episode_limit: 2,
        category_source: 'Keeper_memory_os_types.category_to_string',
        claim_kind_source: 'Keeper_memory_os_types.claim_kind_to_string',
        recall_block: 'Keeper_memory_os_recall.render_if_enabled',
        prompt_record: 'Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall',
      },
      facts_store: '.masc/config/keepers/masc-improver.facts.jsonl',
      episodes_store: '.masc/config/keepers/masc-improver/episodes',
      recall_enabled: true,
      now: 1_790_000_000,
      now_iso: '2026-09-21T00:00:00Z',
      read_errors: [{ scope: 'facts', error: 'one malformed row skipped' }],
      episodes: {
        tail_limit: 12,
        shown: 2,
        current: 2,
        expired: 0,
        terminal_markers: 2,
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
            source_turn_range: { lo: 1, hi: 28 },
            summary: '리텐션 코호트 정의를 정리하고 amplitude 쿼리를 표로 캐시함.',
          },
          {
            trace_id: 'trace-fallback',
            generation: 4,
            created_at: 1_789_950_000,
            created_at_iso: '2026-09-20T...Z',
            valid_until: null,
            valid_until_iso: null,
            current: true,
            terminal_marker: MEMORY_OS_LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER,
            claim_count: 1,
            summary: 'unstructured_note: librarian parse fallback (empty response)',
          },
        ],
      },
      facts: {
        tail_limit: 384,
        shown: 3,
        current: 2,
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
            prompt_recallable: true,
            claim_kind: 'durable_knowledge',
            external_ref: { kind: 'pr', id: '22198' },
          },
          {
            claim: 'diagnostic row: operator pin backend source absent',
            category: 'fact',
            source: { trace_id: 'trace-diagnostic', turn: 6, tool_call_id: null },
            first_seen: 1_789_700_000,
            first_seen_iso: '2026-09-10T...Z',
            reference_time: 1_789_700_000,
            valid_until: null,
            valid_until_iso: null,
            last_verified_at: null,
            current: true,
            prompt_recallable: false,
            claim_kind: 'diagnostic',
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
            prompt_recallable: true,
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

function abortablePendingResponse(init?: RequestInit): Promise<Response> {
  return new Promise((_, reject) => {
    const signal = init?.signal
    const abort = () => {
      const error = new Error('Aborted')
      error.name = 'AbortError'
      reject(error)
    }
    if (signal?.aborted) {
      abort()
      return
    }
    signal?.addEventListener('abort', abort, { once: true })
  })
}

function turnRecordsPayloadWithEmptyFallbackFact() {
  const payload = turnRecordsPayload()
  const fact = {
    claim: 'unstructured_note: librarian parse fallback (librarian provider returned empty response): <empty response>',
    category: 'ephemeral',
    source: { trace_id: 'trace-empty-fallback', turn: 9, tool_call_id: null },
    first_seen: 1_789_800_000,
    first_seen_iso: '2026-09-10T...Z',
    reference_time: 1_789_800_000,
    valid_until: null,
    valid_until_iso: null,
    last_verified_at: null,
    current: true,
    prompt_recallable: false,
    claim_kind: 'diagnostic',
  }
  payload.memory_os.facts.items.splice(1, 0, fact)
  payload.memory_os.facts.shown = 4
  payload.memory_os.facts.current = 3
  return payload
}

function turnRecordsPayloadWithoutRecallableFacts() {
  const payload = turnRecordsPayload()
  for (const fact of payload.memory_os.facts.items) {
    fact.prompt_recallable = false
  }
  return payload
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

  it('renders active/latest facts first, with stored time and selection reason', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelectorAll('.mem-store-row').length).toBeGreaterThan(0))
    // Default view is prompt-recallable current rows only, so diagnostics and
    // expired evidence do not dominate the drawer.
    expect(container.textContent).toContain('retention D0 = 가입일, 첫 세션 기준')
    expect(container.textContent).toContain('제약') // constraint chip label
    expect(container.textContent).toContain('저장')
    expect(container.textContent).toContain('검증')
    expect(container.textContent).toContain('active recall candidate')
    expect(container.textContent).toContain('1/3 recallable')
    expect(container.textContent).toContain('핵심 회상 후보')
    expect(container.textContent).toContain('실제 prompt recall 후보 1/1개를 표시')
    expect(container.textContent).not.toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).not.toContain('librarian parse fallback')
    expect(container.textContent).not.toContain('amplitude 캐시는 만료됨')
  })

  it('can expand to all rows and still surfaces unknown taxonomy explicitly', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    const allBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '전체 3')
    expect(allBtn).toBeTruthy()
    fireEvent.click(allBtn!)
    // out-of-vocabulary category surfaces its raw label, not a fabricated kind.
    expect(container.textContent).toContain('Speculation')
    expect(container.textContent).toContain('expired evidence row')
    // legacy external_ref payloads are no longer rendered as status tags.
    expect(container.textContent).not.toContain('pr 22198')
    // NO salience meter — the deleted score model must not reappear.
    expect(container.querySelector('.mem-sal')).toBeFalsy()
  })

  it('keeps diagnostic facts and librarian fallback episodes out of the default recall view', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    expect(container.textContent).not.toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).not.toContain('librarian parse fallback')
    expect(container.textContent).toContain('librarian fallback 진단 1개는 기본 회상 화면에서 접힘')

    const diagnosticBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '진단/증거 1')
    expect(diagnosticBtn).toBeTruthy()
    fireEvent.click(diagnosticBtn!)

    expect(container.textContent).toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).toContain('diagnostic evidence row')
    expect(container.textContent).not.toContain('amplitude 캐시는 만료됨')
    expect(container.textContent).toContain('진단 fallback · librarian')
    expect(container.textContent).toContain('librarian parse fallback')
  })

  it('explains when the active filter hides all stored memory facts', async () => {
    stubFetch(turnRecordsPayloadWithoutRecallableFacts())
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())

    expect(container.textContent).toContain('현재 필터에 표시할 memory-os fact가 없습니다.')
    expect(container.textContent).toContain('recallable=0 · diagnostic=2 · total=3')

    const allBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '전체 3')
    expect(allBtn).toBeTruthy()
    fireEvent.click(allBtn!)
    expect(container.textContent).toContain('retention D0 = 가입일, 첫 세션 기준')
  })

  it('does not leak empty librarian fallback categories into the default recall filter', async () => {
    stubFetch(turnRecordsPayloadWithEmptyFallbackFact())
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())

    expect(container.textContent).toContain('1/4 recallable')
    expect(container.textContent).not.toContain('<empty response>')
    expect([...container.querySelectorAll('.mem-filter')].map(b => b.textContent)).not.toContain('◌ 임시')

    const diagnosticBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '진단/증거 2')
    expect(diagnosticBtn).toBeTruthy()
    fireEvent.click(diagnosticBtn!)

    expect(container.textContent).toContain('<empty response>')
    expect([...container.querySelectorAll('.mem-filter')].map(b => b.textContent)).toContain('◌ 임시')
  })

  it('surfaces selection policy and prompt digest lineage without claiming raw full-prompt storage', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-trust')).toBeTruthy())
    expect(container.textContent).toContain('masc-improver + _shared')
    expect(container.textContent).toContain('private + shared recall tiers')
    expect(container.textContent).toContain('800B memory_os_recall')
    expect(container.textContent).toContain('Keeper_memory_os_io.read_facts_tail')
    expect(container.textContent).toContain('Keeper_memory_os_io.read_facts_all')
    expect(container.textContent).toContain('dashboard 384 · prompt 8')
    expect(container.textContent).toContain('_shared · prompt 4')
    expect(container.textContent).toContain('dashboard 12 · prompt 2')
    expect(container.textContent).toContain('Keeper_memory_os_recall.render_if_enabled')
    expect(container.textContent).toContain('Full Prompt')
    expect(container.textContent).toContain('raw text not persisted here')
    expect(container.textContent).toContain('cccc2222dddd')
  })

  it('renders recent recall injection rows from real memory_os_recall prompt blocks', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-tl-row')).toBeTruthy())
    expect(container.textContent).toContain('trace-a#7')
    expect(container.textContent).toContain('cccc2222dddd')
    expect(container.textContent).toContain('800B')
    const recallSection = [...container.querySelectorAll('.turn-sec')].find(sec => (sec.querySelector('h4')?.textContent ?? '') === '최근 회상 · 주입')
    expect(recallSection?.querySelector('.mem-tl-row')?.textContent).toContain('cccc2222dddd')
    expect(recallSection?.querySelector('.mem-disclosure')).toBeFalsy()
  })

  it('surfaces read_errors and renders recall candidates without pin placeholders', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    // read_errors visible (no silent failure)
    expect(container.querySelector('.mem-read-error')?.textContent).toContain('one malformed row skipped')
    // The section shows real recall candidates without the old unbacked operator-pin disclosure.
    const disclosures = [...container.querySelectorAll('.mem-disclosure')].map(d => d.textContent ?? '')
    expect(disclosures.some(t => t.includes('Phase 2'))).toBe(false)
    expect(disclosures.some(t => t.includes('실제 prompt recall 후보 1/1개를 표시'))).toBe(true)
    expect(container.textContent).toContain('핵심 회상 후보')
    // no prototype fixture leakage
    expect(container.querySelector('.mem-pin')).toBeFalsy()
  })

  it('renders the compaction section from real episodes (summary + terminal marker)', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.textContent).toContain('리텐션 코호트 정의'))
    expect(container.textContent).toContain('terminal=handoff_complete')
    expect(container.textContent).toContain('4 claims')
    // source_turn_range projected → episode subtitle shows the compacted turn span.
    expect(container.querySelector('.mem-tl-range')?.textContent).toBe('turn 1–28')
    expect(container.textContent).toContain('turn 1–28')
  })

  it('omits the turn-range subtitle for an episode without source_turn_range (no fabrication)', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    // switch to the 진단/증거 lane where the range-less fallback episode is shown.
    const diagnosticBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '진단/증거 1')
    fireEvent.click(diagnosticBtn!)
    const fallbackRow = [...container.querySelectorAll('.mem-store-row')].find(r =>
      (r.textContent ?? '').includes('librarian parse fallback'))
    expect(fallbackRow).toBeTruthy()
    expect(fallbackRow?.querySelector('.mem-tl-range')).toBeFalsy()
  })

  it('fails closed on an impossible turn range (hi < lo) rather than rendering a fabricated span', async () => {
    const payload = turnRecordsPayload()
    // hi < lo cannot be an inclusive absolute-turn span → decode drops it to null.
    payload.memory_os.episodes.items[0]!.source_turn_range = { lo: 5, hi: 2 }
    stubFetch(payload)
    const { container } = renderInspector()
    await waitFor(() => expect(container.textContent).toContain('리텐션 코호트 정의'))
    // the episode still renders; only the impossible range subtitle is omitted.
    expect(container.querySelector('.mem-tl-range')).toBeFalsy()
    expect(container.textContent).not.toContain('turn 5')
  })

  it('re-binds the one-scope target when the keeper prop changes (no stale keeper identity)', async () => {
    const fetchMock = stubFetch()
    const onClose = vi.fn()
    const keeperA: MemoryKeeper = { id: 'masc-improver', ctx: 0.5, status: 'run' }
    const keeperB: MemoryKeeper = { id: 'sangsu', ctx: 0.4, status: 'run' }
    const { container, rerender } = render(html`<${MemoryInspector} keeper=${keeperA} onClose=${onClose} />`)
    await waitFor(() =>
      expect(fetchMock.mock.calls.some(c =>
        String(c[0]).includes('/api/v1/keepers/masc-improver/turn-records?limit=24'))).toBe(true))
    expect(container.querySelector('.tid')?.textContent).toBe('masc-improver')

    // Reuse the same inspector instance for a different keeper (prop change).
    rerender(html`<${MemoryInspector} keeper=${keeperB} onClose=${onClose} />`)
    await waitFor(() => expect(container.querySelector('.tid')?.textContent).toBe('sangsu'))
    // the next one-scope fetch targets the new keeper, not the stale picked one.
    expect(fetchMock.mock.calls.some(c =>
      String(c[0]).includes('/api/v1/keepers/sangsu/turn-records?limit=24'))).toBe(true)
  })

  it('marks memory-os prompt blocks with a legend tag and renders a current TTL pill', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    // The legend tag marks only the memory contribution blocks (memory_os_recall).
    const memLegRow = [...container.querySelectorAll('.mem-leg')].find(r => r.querySelector('.mem-leg-tag'))
    expect(memLegRow?.textContent).toContain('메모리 회상')
    // a non-memory block (동적 컨텍스트) carries no tag.
    const ctxLegRow = [...container.querySelectorAll('.mem-leg')].find(r =>
      (r.querySelector('.mem-leg-lbl')?.textContent ?? '').includes('동적 컨텍스트'))
    expect(ctxLegRow).toBeTruthy()
    expect(ctxLegRow?.querySelector('.mem-leg-tag')).toBeFalsy()
    // current fact renders a TTL pill, not the removed plain mono span.
    expect(container.querySelector('.mem-ttl.current')).toBeTruthy()
  })

  it('renders an expired TTL pill for a fact past valid_until once expanded to all rows', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    const allBtn = [...container.querySelectorAll('.mem-filter')].find(b => b.textContent === '전체 3')
    fireEvent.click(allBtn!)
    const expiredRow = [...container.querySelectorAll('.mem-store-row')].find(r =>
      (r.textContent ?? '').includes('amplitude 캐시는 만료됨'))
    expect(expiredRow?.querySelector('.mem-ttl.expired')).toBeTruthy()
    expect(expiredRow?.querySelector('.mem-ttl.current')).toBeFalsy()
  })

  it('shows an explicit empty state when memory_os is absent (no fabrication)', async () => {
    stubFetch({ keeper: 'ghost', count: 0, source: 'turn_record', memory_os: null, user_model: null, entries: [] })
    const { container } = renderInspector({ id: 'ghost', ctx: 0, status: 'off' })
    await waitFor(() => expect(container.textContent).toContain('memory-os 소스 없음'))
    expect(container.textContent).toContain('turn-records가 비어 있습니다')
    expect(container.querySelector('.mem-bar')).toBeFalsy()
  })

  it('does not claim turn-records are empty when only the memory_os projection is missing', async () => {
    stubFetch({
      keeper: 'ghost',
      count: 2,
      source: 'turn_record',
      health: 'ok',
      stale_reason: null,
      durable_store: '.masc/keepers/ghost/turn-records',
      skipped_rows: 1,
      memory_os: null,
      user_model: null,
      entries: [],
    })
    const { container } = renderInspector({ id: 'ghost', ctx: 0, status: 'off' })
    await waitFor(() => expect(container.textContent).toContain('memory-os 소스 없음'))
    expect(container.textContent).toContain('turn-records 2건은 있지만 memory_os projection이 null입니다.')
    expect(container.textContent).toContain('source=turn_record · health=ok · stale=none · skipped=1')
    expect(container.textContent).not.toContain('turn-records가 비어 있습니다')
  })
})

describe('MemoryInspector — scope toggle', () => {
  it('switches to the aggregate (전체) view and fetches real keeper memory rows', async () => {
    const fetchMock = stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    const allBtn = [...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')
    expect(allBtn).toBeTruthy()
    fireEvent.click(allBtn!)
    expect(container.querySelector('.tid')?.textContent).toBe('전체 keeper')
    await waitFor(() =>
      expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length)
        .toBe(DEFAULT_MEMORY_KEEPERS.length))
    expect(fetchMock.mock.calls.some(call =>
      String(call[0]).includes('/api/v1/keepers/nick0cave/turn-records?limit=12'))).toBe(true)
    expect(container.textContent).toContain('전체 memory-os')
    expect(container.textContent).toContain(`${DEFAULT_MEMORY_KEEPERS.length}/${DEFAULT_MEMORY_KEEPERS.length} loaded`)
    expect(container.textContent).toContain(`${DEFAULT_MEMORY_KEEPERS.length}/18 recallable`)
    expect(container.textContent).toContain('800B · trace-a#7')
    expect([...container.querySelectorAll('.mem-disclosure')].some(d => (d.textContent ?? '').includes('읽기 전용 집계'))).toBe(true)
    expect(container.textContent).not.toContain('추후 연결')
  })

  it('shows completed aggregate rows while one keeper request is still pending', async () => {
    const fetchMock = vi.fn().mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input)
      if (path.includes('/api/v1/keepers/drifter/turn-records?limit=12')) {
        return abortablePendingResponse(init)
      }
      return Promise.resolve(
        new Response(JSON.stringify(turnRecordsPayload()), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
    })
    vi.stubGlobal('fetch', fetchMock)

    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)

    await waitFor(() =>
      expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length)
        .toBe(DEFAULT_MEMORY_KEEPERS.length - 1))
    expect(container.textContent).toContain(`${DEFAULT_MEMORY_KEEPERS.length - 1}/${DEFAULT_MEMORY_KEEPERS.length} loaded`)
    expect(container.textContent).toContain('전체 keeper memory-os 집계 불러오는 중')
    expect([...container.querySelectorAll('.mem-td-id .mono')].map(cell => cell.textContent))
      .not.toContain('drifter')
  })

  it('maps roster status to dot state run→ok / pause→idle / off→bad', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    await waitFor(() =>
      expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length)
        .toBe(DEFAULT_MEMORY_KEEPERS.length))
    const dotClassFor = (id: string): string | undefined => {
      const row = [...container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)')].find(r =>
        (r.querySelector('.mem-td-id .mono')?.textContent ?? '') === id)
      return row?.querySelector('.mem-dot')?.className
    }
    expect(dotClassFor('nick0cave')).toContain('ok')
    expect(dotClassFor('qa-king')).toContain('idle')
    expect(dotClassFor('drifter')).toContain('bad')
  })

  it('renders a fleet category distribution over real fact.category', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    await waitFor(() => expect(container.querySelector('.mem-kd-row')).toBeTruthy())
    expect(container.textContent).toContain('category별 분포')
    // 6 keepers × { constraint, fact, Speculation(unknown) } → 3 distinct category rows.
    const kdRows = [...container.querySelectorAll('.mem-kd-row')]
    expect(kdRows.length).toBe(3)
    const labels = kdRows.map(r => r.querySelector('.mem-kind')?.textContent ?? '')
    expect(labels.some(l => l.includes('제약'))).toBe(true)
    expect(labels.some(l => l.includes('사실'))).toBe(true)
    expect(labels.some(l => l.includes('Speculation'))).toBe(true) // raw unknown label preserved
    const constraintRow = kdRows.find(r => (r.querySelector('.mem-kind')?.textContent ?? '').includes('제약'))
    expect(constraintRow?.querySelector('.mem-kd-n')?.textContent).toBe('6')
  })

  it('renders a fleet-wide recent facts list labelled by keeper (not salience-sorted)', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    await waitFor(() => expect(container.textContent).toContain('최근 확인된 사실 · 전체'))
    const recentSection = [...container.querySelectorAll('.turn-sec')].find(sec =>
      (sec.querySelector('h4')?.textContent ?? '').includes('최근 확인된 사실'))
    expect(recentSection).toBeTruthy()
    const rows = [...recentSection!.querySelectorAll('.mem-store-row')]
    // bounded fleet slice (AGGREGATE_RECENT_FACTS_LIMIT = 8)
    expect(rows.length).toBe(8)
    // each row is labelled by its owning keeper via srcOverride — a real roster id.
    const srcLabels = rows.map(r => r.querySelector('.mem-src')?.textContent ?? '')
    expect(srcLabels.every(label => DEFAULT_MEMORY_KEEPERS.some(k => k.id === label))).toBe(true)
    expect(container.textContent).toContain('salience 정렬 아님')
  })

  it('switches to the individual view for the clicked aggregate keeper row (onPick)', async () => {
    const fetchMock = stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    await waitFor(() =>
      expect(container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)').length)
        .toBe(DEFAULT_MEMORY_KEEPERS.length))
    const targetRow = [...container.querySelectorAll('.mem-table .mem-tr:not(.mem-th)')].find(r =>
      (r.querySelector('.mem-td-id .mono')?.textContent ?? '') === 'sangsu')
    expect(targetRow).toBeTruthy()
    fireEvent.click(targetRow!)
    // pick → one scope bound to the clicked keeper, which loads its own turn-records.
    await waitFor(() => expect(container.querySelector('.tid')?.textContent).toBe('sangsu'))
    expect(fetchMock.mock.calls.some(call =>
      String(call[0]).includes('/api/v1/keepers/sangsu/turn-records?limit=24'))).toBe(true)
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

  it('latestEntryWithBlocks skips an empty-block tail turn and returns the last assembled prompt', () => {
    const mkRow = (turn: number, blocks: { block: string; bytes: number; digest: string }[]): TurnRecordRow => ({
      record: {
        keeper: 'k', trace_id: 't', absolute_turn: turn, ts: turn, runtime_profile: 'local',
        blocks, execution_ids: [],
      },
      diff_vs_prev: null,
    })
    const assembled = mkRow(1, [{ block: 'persona', bytes: 100, digest: 'd' }])
    const errorTail = mkRow(2, []) // e.g. an error turn with no prompt blocks
    // last row has no blocks → fall back to the most recent row that does
    expect(latestEntryWithBlocks([assembled, errorTail])?.record.absolute_turn).toBe(1)
    // empty input → null, not a fabricated row
    expect(latestEntryWithBlocks([])).toBeNull()
    expect(latestEntryWithBlocks([errorTail])).toBeNull()
  })

  it('recentMemoryRecallInjections returns newest real memory_os_recall blocks only', () => {
    const mkRow = (turn: number, block: string, bytes: number): TurnRecordRow => ({
      record: {
        keeper: 'k',
        trace_id: `trace-${turn}`,
        absolute_turn: turn,
        ts: turn,
        runtime_profile: 'local',
        blocks: [{ block, bytes, digest: `digest-${turn}` }],
        execution_ids: [],
      },
      diff_vs_prev: null,
    })
    expect(recentMemoryRecallInjections([
      mkRow(1, 'memory_os_recall', 100),
      mkRow(2, 'persona', 200),
      mkRow(3, 'memory_os_recall', 0),
      mkRow(4, 'memory_os_recall', 400),
    ])).toEqual([
      { traceId: 'trace-4', turn: 4, ts: 4, bytes: 400, digest: 'digest-4' },
      { traceId: 'trace-1', turn: 1, ts: 1, bytes: 100, digest: 'digest-1' },
    ])
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

  it('factTtlLabel renders a future expiry as remaining TTL ("…후"), never "지금"', () => {
    const makeFact = (over: Partial<MemoryOsFact>): MemoryOsFact => ({
      claim: 'x',
      category: { tag: 'fact' },
      source: { trace_id: 't', turn: 0, tool_call_id: null },
      first_seen: 0,
      first_seen_iso: null,
      reference_time: 0,
      valid_until: null,
      valid_until_iso: null,
      last_verified_at: null,
      current: true,
      prompt_recallable: true,
      claim_kind: null,
      ...over,
    })
    const nowSec = Math.floor(Date.now() / 1000)
    // permanent fact
    expect(factTtlLabel(makeFact({ valid_until: null, current: true }))).toBe('영구')
    // current ⟺ valid_until in the future: must show remaining TTL, not collapse
    // to "지금" (the drift this guards — formatTimeAgo floors the future to 0).
    const live = factTtlLabel(makeFact({ valid_until: nowSec + 2 * 3600, current: true }))
    expect(live).not.toContain('지금')
    expect(live).toContain('후')
    // an already-expired fact keeps the past form
    const dead = factTtlLabel(makeFact({ valid_until: nowSec - 2 * 3600, current: false }))
    expect(dead).toContain('전')
  })

  it('sortMemoryFactsForReview puts current, most-recent evidence first', () => {
    const mkFact = (claim: string, current: boolean, reference_time: number): MemoryOsFact => ({
      claim,
      category: { tag: 'fact' },
      source: { trace_id: 't', turn: 1, tool_call_id: null },
      first_seen: reference_time,
      first_seen_iso: null,
      reference_time,
      valid_until: null,
      valid_until_iso: null,
      last_verified_at: null,
      current,
      prompt_recallable: true,
      claim_kind: null,
    })
    expect(sortMemoryFactsForReview([
      mkFact('expired-new', false, 30),
      mkFact('current-old', true, 10),
      mkFact('current-new', true, 20),
    ]).map(f => f.claim)).toEqual(['current-new', 'current-old', 'expired-new'])
  })

  it('factSelectionReason explains currentness, category, and claim kind', () => {
    const fact: MemoryOsFact = {
      claim: 'x',
      category: { tag: 'constraint' },
      source: { trace_id: 't', turn: 1, tool_call_id: null },
      first_seen: 0,
      first_seen_iso: null,
      reference_time: 0,
      valid_until: null,
      valid_until_iso: null,
      last_verified_at: null,
      current: true,
      prompt_recallable: true,
      claim_kind: 'durable_knowledge',
    }
    expect(factSelectionReason(fact)).toBe('active recall candidate · 제약 · durable')
    expect(factSelectionReason({ ...fact, prompt_recallable: false, claim_kind: 'diagnostic' })).toBe(
      'diagnostic evidence row · 제약 · diagnostic',
    )
  })
})
