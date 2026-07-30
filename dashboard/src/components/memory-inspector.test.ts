// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_MEMORY_KEEPERS,
  MemoryInspector,
  factCategoryMeta,
  factSelectionReason,
  latestEntryWithInputComponents,
  memCompositionFromInputComponents,
  memFmtBytes,
  memFmtTok,
  promptBlockMeta,
  recentMemoryRecallInjections,
  sortMemoryFactsForReview,
  type MemoryKeeper,
} from './memory-inspector'
import {
  type MemoryOsFact,
  type TurnBlockId,
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
    skipped_rows: 0,
    source: 'turn_record',
    producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
    durable_store: '.masc/keepers/masc-improver/turn-records',
    dashboard_surface: '/api/v1/keepers/:name/turn-records',
    freshness_slo_s: 300,
    latest_ts_unix: 1_789_999_000,
    latest_ts_iso: '2026-09-21T13:56:40Z',
    latest_age_s: 10,
    health: 'ok',
    stale_reason: null,
    memory_os: {
      keeper: 'masc-improver',
      source: 'memory_os_files',
      producer: 'keeper_librarian|keeper_memory_os_recall',
      selection_policy: {
        keeper_scope: 'masc-improver',
        facts_source: 'Keeper_memory_os_io.read_facts_all_for_keepers_dir',
        episodes_source: 'Keeper_memory_os_io.read_episodes_all_for_keepers_dir',
        category_source: 'Keeper_memory_os_types.category_to_string',
        recall_block: 'Keeper_memory_os_recall.render_if_enabled',
        prompt_record: 'Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall',
      },
      facts_store: '.masc/config/keepers/masc-improver.facts.jsonl',
      episodes_store: '.masc/config/keepers/masc-improver/episodes',
      recall_enabled: true,
      read_errors: [{ scope: 'facts', error: 'fact store decode failed' }],
      episodes: {
        shown: 2,
        items: [
          {
            trace_id: 'trace-ep1',
            generation: 3,
            created_at: 1_789_900_000,
            claim_count: 4,
            source_turn_range: { lo: 1, hi: 28 },
            summary: '리텐션 코호트 정의를 정리하고 amplitude 쿼리를 표로 캐시함.',
          },
          {
            trace_id: 'trace-diagnostic',
            generation: 4,
            created_at: 1_789_950_000,
            claim_count: 1,
            source_turn_range: null,
            summary: 'provider response diagnostic',
          },
        ],
      },
      facts: {
        shown: 3,
        items: [
          {
            claim: 'retention D0 = 가입일, 첫 세션 기준',
            category: 'constraint',
            source: { trace_id: 'trace-a', turn: 4 },
            first_seen: 1_789_000_000,
            first_seen_iso: '2026-09-10T00:26:40Z',
            reference_time: 1_789_500_000,
            last_verified_at: 1_789_500_000,
          },
          {
            claim: 'diagnostic row: operator pin backend source absent',
            category: 'fact',
            source: { trace_id: 'trace-diagnostic', turn: 6 },
            first_seen: 1_789_700_000,
            first_seen_iso: '2026-09-18T02:53:20Z',
            reference_time: 1_789_700_000,
            last_verified_at: null,
          },
          {
            claim: 'amplitude 캐시 기준이 변경됨',
            category: 'lesson',
            source: { trace_id: 'trace-b', turn: 5 },
            first_seen: 1_789_100_000,
            first_seen_iso: '2026-09-11T04:13:20Z',
            reference_time: 1_789_100_000,
            last_verified_at: null,
          },
        ],
      },
    },
    entries: [
      {
        record: {
          keeper: 'masc-improver',
          trace_id: 'trace-a',
          absolute_turn: 7,
          turn_ref: 'trace-a#7',
          ts: 1_789_999_000,
          runtime_profile: 'local',
          blocks: [
            { block: 'persona', bytes: 1200, digest: 'aaaa1111bbbb' },
            { block: 'memory_os_recall', bytes: 800, digest: 'cccc2222dddd' },
            { block: 'dynamic_context', bytes: 400, digest: 'eeee3333ffff' },
            { block: 'temporal_summary', bytes: 0, digest: '000000000000' },
          ],
          input_components: [
            { component: 'prompt.persona', bytes: 1200 },
            { component: 'prompt.memory_os_recall', bytes: 800 },
            { component: 'prompt.dynamic_context', bytes: 400 },
            { component: 'tool_schemas', bytes: 600 },
          ],
          request_runtime_profile: 'local',
          request_body_bytes: 3412,
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

  it('builds the composition bar from final provider input components', async () => {
    stubFetch()
    const { container } = renderInspector()
    const bar = await waitFor(() => {
      const b = container.querySelector('.mem-bar')
      expect(b).toBeTruthy()
      return b!
    })
    // 4 non-zero input components → 4 segments + 4 legend rows.
    expect(bar.querySelectorAll('span').length).toBe(4)
    expect(container.querySelectorAll('.mem-leg').length).toBe(4)
    // Attributed bytes and provider token usage stay separate measurements.
    expect(container.querySelector('.mem-compo-tot')?.textContent).toBe('attributed 2.9KB')
    expect(container.querySelector('.mem-compo-sub')?.textContent).toContain('3.5k tok')
    // block labels come from the Prompt_block_id mirror, not raw tokens.
    expect(container.textContent).toContain('메모리 회상')
    expect(container.textContent).toContain('동적 컨텍스트')
  })

  it('renders all facts in persisted source order with stored timestamps', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelectorAll('.mem-store-row').length).toBeGreaterThan(0))
    expect(container.textContent).toContain('retention D0 = 가입일, 첫 세션 기준')
    expect(container.textContent).toContain('제약') // constraint chip label
    expect(container.textContent).toContain('저장')
    expect(container.textContent).toContain('검증')
    expect(container.textContent).toContain('persisted row')
    expect(container.textContent).toContain('3 rows')
    expect(container.textContent).not.toContain('핵심 회상 후보')
    expect(container.textContent).toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).toContain('provider response diagnostic')
    expect(container.textContent).toContain('amplitude 캐시 기준이 변경됨')
  })

  it('renders a closed taxonomy category without a score model', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    expect(container.textContent).toContain('교훈')
    expect(container.textContent).toContain('persisted row')
    // NO salience meter — the deleted score model must not reappear.
    expect(container.querySelector('.mem-sal')).toBeFalsy()
  })

  it('shows every persisted fact without a default category or claim-kind gate', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    expect(container.textContent).toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).toContain('amplitude 캐시 기준이 변경됨')
    expect(container.textContent).toContain('provider response diagnostic')
  })

  it('surfaces selection policy and prompt digest lineage without claiming raw full-prompt storage', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-trust')).toBeTruthy())
    expect(container.textContent).toContain('masc-improver')
    expect(container.textContent).toContain('keeper-local persisted source order')
    expect(container.textContent).toContain('800B memory_os_recall')
    expect(container.textContent).toContain('Keeper_memory_os_io.read_facts_all_for_keepers_dir')
    expect(container.textContent).toContain('Keeper_memory_os_io.read_episodes_all_for_keepers_dir')
    expect(container.textContent).toContain('all rows · source order')
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

  it('surfaces read_errors while preserving every stored fact', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    // read_errors visible (no silent failure)
    expect(container.querySelector('.mem-read-error')?.textContent).toContain('fact store decode failed')
    const disclosures = [...container.querySelectorAll('.mem-disclosure')].map(d => d.textContent ?? '')
    expect(disclosures.some(t => t.includes('Phase 2'))).toBe(false)
    expect(container.textContent).toContain('diagnostic row: operator pin backend source absent')
    expect(container.textContent).toContain('amplitude 캐시 기준이 변경됨')
    // no prototype fixture leakage
    expect(container.querySelector('.mem-pin')).toBeFalsy()
  })

  it('renders the compaction section from real episodes', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.textContent).toContain('리텐션 코호트 정의'))
    expect(container.textContent).toContain('4 claims')
    // source_turn_range projected → episode subtitle shows the compacted turn span.
    expect(container.querySelector('.mem-tl-range')?.textContent).toBe('turn 1–28')
    expect(container.textContent).toContain('turn 1–28')
  })

  it('omits the turn-range subtitle for an episode without source_turn_range (no fabrication)', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    const diagnosticRow = [...container.querySelectorAll('.mem-store-row')].find(r =>
      (r.textContent ?? '').includes('provider response diagnostic'))
    expect(diagnosticRow).toBeTruthy()
    expect(diagnosticRow?.querySelector('.mem-tl-range')).toBeFalsy()
  })

  it('rejects an impossible turn range (hi < lo) instead of hiding the malformed field', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.episodes.items[0]!.source_turn_range = { lo: 5, hi: 2 }
    stubFetch(payload)
    const { container } = renderInspector()
    await waitFor(() => {
      expect(container.textContent).toContain('유효하지 않은 keeper turn record payload')
    })
    expect(container.querySelector('.mem-tl-range')).toBeFalsy()
    expect(container.querySelector('.mem-bar')).toBeFalsy()
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

  it('marks only memory-os prompt blocks with a legend tag', async () => {
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
    expect(container.querySelector('.mem-ttl')).toBeFalsy()
  })

  it('fails loudly when the required memory_os projection is null', async () => {
    stubFetch({ keeper: 'ghost', count: 0, source: 'turn_record', memory_os: null, entries: [] })
    const { container } = renderInspector({ id: 'ghost', ctx: 0, status: 'off' })
    await waitFor(() => {
      expect(container.textContent).toContain('유효하지 않은 keeper turn record payload')
    })
    expect(container.querySelector('.mem-bar')).toBeFalsy()
  })

  it('fails loudly when the required memory_os projection key is absent', async () => {
    stubFetch({
      keeper: 'ghost',
      count: 2,
      source: 'turn_record',
      health: 'ok',
      stale_reason: null,
      durable_store: '.masc/keepers/ghost/turn-records',
      skipped_rows: 1,
      entries: [],
    })
    const { container } = renderInspector({ id: 'ghost', ctx: 0, status: 'off' })
    await waitFor(() => {
      expect(container.textContent).toContain('유효하지 않은 keeper turn record payload')
    })
    expect(container.querySelector('.mem-bar')).toBeFalsy()
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
    expect(container.textContent).toContain(`${DEFAULT_MEMORY_KEEPERS.length * 3} rows`)
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
    // 6 keepers × { constraint, fact, lesson } → 3 distinct category rows.
    const kdRows = [...container.querySelectorAll('.mem-kd-row')]
    expect(kdRows.length).toBe(3)
    const labels = kdRows.map(r => r.querySelector('.mem-kind')?.textContent ?? '')
    expect(labels.some(l => l.includes('제약'))).toBe(true)
    expect(labels.some(l => l.includes('사실'))).toBe(true)
    expect(labels.some(l => l.includes('교훈'))).toBe(true)
    const constraintRow = kdRows.find(r => (r.querySelector('.mem-kind')?.textContent ?? '').includes('제약'))
    expect(constraintRow?.querySelector('.mem-kd-n')?.textContent).toBe('6')
  })

  it('renders every fleet fact in keeper source order', async () => {
    stubFetch()
    const { container } = renderInspector()
    await waitFor(() => expect(container.querySelector('.mem-bar')).toBeTruthy())
    fireEvent.click([...container.querySelectorAll('.mem-scope button')].find(b => b.textContent === '전체')!)
    await waitFor(() => expect(container.textContent).toContain('저장된 사실 · 전체'))
    const recentSection = [...container.querySelectorAll('.turn-sec')].find(sec =>
      (sec.querySelector('h4')?.textContent ?? '').includes('저장된 사실'))
    expect(recentSection).toBeTruthy()
    const rows = [...recentSection!.querySelectorAll('.mem-store-row')]
    expect(rows.length).toBe(DEFAULT_MEMORY_KEEPERS.length * 3)
    // each row is labelled by its owning keeper via srcOverride — a real roster id.
    const srcLabels = rows.map(r => r.querySelector('.mem-src')?.textContent ?? '')
    expect(srcLabels.every(label => DEFAULT_MEMORY_KEEPERS.some(k => k.id === label))).toBe(true)
    expect(container.textContent).toContain('keeper별 source order')
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

  it('memCompositionFromInputComponents sums real bytes and drops zero-byte components', () => {
    const comp = memCompositionFromInputComponents([
      { component: 'prompt.persona', bytes: 1200 },
      { component: 'prompt.memory_os_recall', bytes: 800 },
      { component: 'message_user', bytes: 0 },
    ])
    expect(comp.totalBytes).toBe(2000)
    expect(comp.parts.map(p => p.key)).toEqual(['prompt.persona', 'prompt.memory_os_recall'])
    expect(comp.parts[0]?.lbl).toBe('페르소나')
  })

  it('latestEntryWithInputComponents skips a pre-serialization tail turn', () => {
    const mkRow = (
      turn: number,
      input_components: TurnRecordRow['record']['input_components'],
    ): TurnRecordRow => ({
      record: {
        keeper: 'k', trace_id: 't', absolute_turn: turn, ts: turn, runtime_profile: 'local',
        turn_ref: `t#${turn}`,
        blocks: [],
        input_components,
        request_runtime_profile: input_components.length > 0 ? 'local' : null,
        request_body_bytes: input_components.length > 0 ? 100 : null,
        execution_ids: [],
      },
      diff_vs_prev: null,
    })
    const assembled = mkRow(1, [{ component: 'prompt.persona', bytes: 100 }])
    const errorTail = mkRow(2, [])
    expect(latestEntryWithInputComponents([assembled, errorTail])?.record.absolute_turn).toBe(1)
    // empty input → null, not a fabricated row
    expect(latestEntryWithInputComponents([])).toBeNull()
    expect(latestEntryWithInputComponents([errorTail])).toBeNull()
  })

  it('recentMemoryRecallInjections returns newest real memory_os_recall blocks only', () => {
    const mkRow = (
      turn: number,
      block: TurnBlockId,
      bytes: number,
    ): TurnRecordRow => ({
      record: {
        keeper: 'k',
        trace_id: `trace-${turn}`,
        absolute_turn: turn,
        turn_ref: `trace-${turn}#${turn}`,
        ts: turn,
        runtime_profile: 'local',
        blocks: [{ block, bytes, digest: `digest-${turn}` }],
        input_components: [],
        request_runtime_profile: null,
        request_body_bytes: null,
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

  it('promptBlockMeta maps every current Prompt_block_id token', () => {
    expect(promptBlockMeta('persona').lbl).toBe('페르소나')
    expect(promptBlockMeta('dynamic_context').lbl).toBe('동적 컨텍스트')
    expect(promptBlockMeta('temporal_summary').lbl).toBe('시간 요약')
    expect(promptBlockMeta('memory_os_recall').lbl).toBe('메모리 회상')
  })

  it('factCategoryMeta covers every closed taxonomy arm', () => {
    const tags = [
      'code_change', 'fact', 'preference', 'blocker', 'goal',
      'constraint', 'validated_approach', 'lesson',
    ] as const
    for (const tag of tags) {
      const meta = factCategoryMeta({ tag })
      expect(meta.lbl.length).toBeGreaterThan(0)
      expect(meta.glyph.length).toBeGreaterThan(0)
    }
  })

  it('sortMemoryFactsForReview preserves persisted source order', () => {
    const mkFact = (claim: string, reference_time: number): MemoryOsFact => ({
      claim,
      category: { tag: 'fact' },
      source: { trace_id: 't', turn: 1, tool_call_id: null },
      first_seen: reference_time,
      first_seen_iso: '1970-01-01T00:00:00Z',
      reference_time,
      last_verified_at: null,
    })
    expect(sortMemoryFactsForReview([
      mkFact('first', 30),
      mkFact('second', 10),
      mkFact('third', 20),
    ]).map(f => f.claim)).toEqual(['first', 'second', 'third'])
  })

  it('factSelectionReason explains persistence and category', () => {
    const fact: MemoryOsFact = {
      claim: 'x',
      category: { tag: 'constraint' },
      source: { trace_id: 't', turn: 1, tool_call_id: null },
      first_seen: 0,
      first_seen_iso: '1970-01-01T00:00:00Z',
      reference_time: 0,
      last_verified_at: null,
    }
    expect(factSelectionReason(fact)).toBe('persisted row · 제약')
  })
})
