// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const promptApi = vi.hoisted(() => ({
  fetchKeeperLastPrompt: vi.fn(),
  fetchKeeperOperatorNote: vi.fn(),
  fetchKeeperRawTrace: vi.fn(),
  fetchKeeperRawTraces: vi.fn(),
  putKeeperOperatorNote: vi.fn(),
}))

vi.mock('../api/dashboard-keeper-prompt', () => promptApi)
import {
  MemoryInspector,
  factCategoryMeta,
  latestEntryWithBlocks,
  latestEntryWithInputComponents,
  memCompositionFromBlocks,
  memCompositionFromInputComponents,
  memFmtBytes,
  memFmtTok,
  recentMemoryRecallInjections,
  sortMemoryFactsForReview,
  storeRowMatches,
  storeRowsFromSnapshot,
  type MemoryKeeper,
  type StoreRow,
} from './memory-inspector'
import {
  type MemoryOsFact,
  type MemoryOsTurnRecordSnapshot,
  type TurnRecordRow,
} from '../api/dashboard'
import { clearStoredToken, setStoredToken } from '../api/core'

const keeper: MemoryKeeper = {
  id: 'masc-improver',
  status: 'run',
}

const memoryId = (digit: string) => `sha256:${digit.repeat(64)}`

function fact(
  memoryId: string,
  claim: string,
  current: boolean,
  category: MemoryOsFact['category']['tag'] = 'fact',
): Record<string, unknown> {
  return {
    memory_id: memoryId,
    claim,
    category,
    first_seen: 1_700_000_000,
    current,
    basis: { kind: 'observed' },
  }
}

function turnRecordsPayload() {
  const retained = fact(memoryId('a'), '계속 유지할 핵심 기억', true, 'constraint')
  const added = fact(memoryId('b'), '이번 revision에 새로 들어온 기억', true)
  const removed = fact(memoryId('c'), '이번 revision에서 사라진 기억', false, 'lesson')
  return {
    keeper: keeper.id,
    count: 1,
    skipped_rows: 0,
    source: 'turn_record',
    producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
    durable_store: '.masc/keepers/masc-improver/turn-records',
    dashboard_surface: '/api/v1/keepers/:name/turn-records',
    freshness_slo_s: 300,
    live_turn_in_progress: false,
    live_turn_started_at_unix: null,
    live_turn_last_progress_at_unix: null,
    latest_ts_unix: 1_700_000_000,
    latest_ts_iso: '2023-11-14T22:13:20Z',
    latest_age_s: 10,
    health: 'ok',
    stale_reason: null,
    memory_os: {
      keeper: keeper.id,
      snapshot_store: '.masc/keepers/masc-improver.memory-current.json',
      recall_enabled: true,
      revision: 12,
      updated_at: 1_700_000_000,
      update_source: {
        kind: 'explicit_retract',
        trace_id: 'trace-a',
      },
      read_errors: [],
      facts: {
        shown: 2,
        current: 2,
        items: [retained, added],
      },
      change: {
        added: [added],
        removed: [removed],
        retained: 1,
        invalidated: [],
      },
    },
    entries: [{
      record: {
        execution_ids: [],
        keeper: keeper.id,
        agent_name: `keeper-${keeper.id}-agent`,
        generation: 1,
        turn_kind: 'autonomous',
        raw_trace_run_ref: null,
        trace_id: 'trace-a',
        absolute_turn: 7,
        turn_ref: 'trace-a#7',
        blocks: [
          { block: 'keeper_instructions', bytes: 1_200, digest: 'a'.repeat(64) },
          { block: 'memory_os_recall', bytes: 800, digest: 'c'.repeat(64) },
        ],
        input_components: [
          { component: 'prompt.keeper_instructions', bytes: 1_200 },
          { component: 'prompt.memory_os_recall', bytes: 800 },
          { component: 'tool_schemas', bytes: 1_600 },
          { component: 'message_user', bytes: 100 },
          { component: 'message_tool_result', bytes: 500 },
        ],
        request_runtime_profile: 'anthropic.fallback',
        request_body_bytes: 560_513,
        runtime_profile: 'local',
        input_tokens: 3_500,
        output_tokens: 200,
        context_window: 200_000,
        ts: 1_700_000_000,
      },
      diff_vs_prev: null,
    }],
  }
}

function stubFetch(payload: unknown = turnRecordsPayload()) {
  // A Response body can only be read once, and fetchKeeperTurnRecords issues two
  // requests: ensureDevToken's bootstrap call, then the turn-records call.
  // mockResolvedValue hands back the same instance both times, so the second
  // read failed with "failed to read response body" and the panel reported a
  // transport error before it ever decoded a payload. Build a fresh Response per
  // call instead.
  const fetchMock = vi.fn().mockImplementation(
    async () =>
      new Response(JSON.stringify(payload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
  )
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

beforeEach(() => {
  setStoredToken('memory-inspector-test-token', { source: 'manual' })
})

afterEach(() => {
  cleanup()
  clearStoredToken()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

describe('MemoryInspector current snapshot', () => {
  it('renders exact provider composition and the current snapshot delta', async () => {
    stubFetch()
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.textContent).toContain('이번 revision에 새로 들어온 기억')
    })

    const text = container.textContent ?? ''
    expect(text).toContain('계속 유지할 핵심 기억')
    expect(text).toContain('이번 revision에서 사라진 기억')
    expect(text).toContain('revision 12')
    expect(text).toContain('latest snapshot writer')
    expect(text).toContain('exact current facts · no ranking/truncation')
    expect(text).toContain('547.4KB wire')
    expect(text).toContain('anthropic.fallback')
    expect(text).toContain('도구 스키마')
    expect(text).toContain('도구 결과')
    expect(text).not.toContain('episodes_store')
    expect(text).not.toContain('valid_until')
    expect(text).not.toContain('claim_kind')
    expect(text).not.toContain('expired')
  })

  it('lists the store with the revision delta in place, one meta line per row', async () => {
    stubFetch()
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )
    const section = await waitFor(() => {
      const found = [...container.querySelectorAll('.turn-sec')].find(sec =>
        sec.querySelector('h4')?.textContent?.includes('장기 메모리 스토어'))
      expect(found).toBeDefined()
      return found as HTMLElement
    })

    // head: store size (current facts only) + latest delta
    const head = [...section.querySelectorAll('.mem-sec-head .mem-n')].map(n => n.textContent)
    expect(head).toEqual(['2', '추가 1 · 제거 1 · 지지 무효화 0 · 유지 1'])

    // rows: current snapshot order, then the removed rows of the latest revision
    const rows = [...section.querySelectorAll('.mem-store-row')]
    expect(rows.map(row => row.querySelector('.mem-store-text')?.textContent)).toEqual([
      '계속 유지할 핵심 기억',
      '이번 revision에 새로 들어온 기억',
      '이번 revision에서 사라진 기억',
    ])
    expect(rows.map(row => row.querySelector('.mem-delta')?.textContent ?? null)).toEqual([
      null,
      '+ 추가됨 · 현재 기억에 들어옴',
      '− 제거됨 · 현재 기억에서 빠짐',
    ])
    expect(rows.map(row => row.classList.contains('removed'))).toEqual([false, false, true])

    // one meta line: current-state chip from the live flag + insertion age
    // (absolute instant in the title); no per-row reason line
    const retained = rows[0] as HTMLElement
    expect(retained.querySelector('.mem-state.current')?.textContent).toBe('유효')
    expect(retained.textContent).toContain('관측')
    const age = [...retained.querySelectorAll('.mem-store-meta span')]
      .find(span => span.textContent?.startsWith('저장 ')) as HTMLElement
    expect(age.textContent).toMatch(/^저장 /)
    expect(age.getAttribute('title')).toMatch(/^20\d\d/)
    expect((rows[1] as HTMLElement).querySelector('.mem-state.current')?.textContent).toBe('유효')
    expect((rows[2] as HTMLElement).querySelector('.mem-state.removed')?.textContent).toBe('제거됨')

    // the delta lives in the store list; each claim is rendered once
    const headers = [...container.querySelectorAll('.turn-sec h4')].map(h => h.textContent ?? '')
    expect(headers).toEqual([
      '최종 provider 입력 구성',
      '회상 연결 · Full Prompt',
      '현재 기억 계약 · explicit_retract',
      '장기 메모리 스토어 · memory-os',
      '최근 회상 · 주입',
    ])
    expect(container.textContent?.split('이번 revision에 새로 들어온 기억').length).toBe(2)

    expect(section.querySelectorAll('.mem-store-row')).toHaveLength(3)
  })

  it('filters the store by category chip and by the latest delta', async () => {
    stubFetch()
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )
    const chips = await waitFor(() => {
      const found = [...container.querySelectorAll('.mem-filters .mem-filter')]
      expect(found.length).toBeGreaterThan(0)
      return found as HTMLButtonElement[]
    })
    expect(chips.map(chip => chip.textContent)).toEqual([
      '전체',
      '▢ 제약',
      '◈ 사실',
      '★ 교훈',
      '± 변경 2',
    ])
    const visible = () =>
      [...container.querySelectorAll('.mem-store-row .mem-store-text')].map(n => n.textContent)

    fireEvent.click(chips[4] as HTMLButtonElement)
    expect(visible()).toEqual(['이번 revision에 새로 들어온 기억', '이번 revision에서 사라진 기억'])
    expect(container.querySelector('.mem-filter.on')?.textContent).toBe('± 변경 2')

    fireEvent.click(chips[1] as HTMLButtonElement)
    expect(visible()).toEqual(['계속 유지할 핵심 기억'])

    fireEvent.click(chips[0] as HTMLButtonElement)
    expect(visible().length).toBe(3)
  })

  it('keeps only the delta chip when every row shares one category', async () => {
    const payload = turnRecordsPayload()
    for (const row of [...payload.memory_os.facts.items, ...payload.memory_os.change.removed]) {
      Object.assign(row, { category: 'fact' })
    }
    stubFetch(payload)
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(container.textContent).toContain('계속 유지할 핵심 기억')
    })
    expect([...container.querySelectorAll('.mem-filter')].map(c => c.textContent)).toEqual([
      '전체',
      '± 변경 2',
    ])
  })

  it('omits the delta chip when the latest revision changed nothing', async () => {
    const payload = turnRecordsPayload()
    payload.memory_os.change = { added: [], removed: [], retained: 2, invalidated: [] }
    stubFetch(payload)
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(container.textContent).toContain('계속 유지할 핵심 기억')
    })
    expect([...container.querySelectorAll('.mem-filter')].map(c => c.textContent)).toEqual([
      '전체',
      '▢ 제약',
      '◈ 사실',
    ])
    expect(container.querySelector('.mem-delta')).toBeNull()
    expect([...container.querySelectorAll('.mem-sec-head .mem-n')].map(n => n.textContent)).toEqual(['2', '추가 0 · 제거 0 · 지지 무효화 0 · 유지 2'])
  })

  it('renders derived proof basis and exact missing premises for support retraction', async () => {
    const payload = turnRecordsPayload()
    const removed = payload.memory_os.change.removed[0]!
    const missing = memoryId('f')
    Object.assign(removed, {
      basis: {
        kind: 'derived',
        derivations: [{ rule_id: 'removed_support', premise_ids: [missing] }],
      },
    })
    Object.assign(payload.memory_os.change, {
      invalidated: [{
        fact: removed,
        missing_premise_ids: [missing],
      }],
    })
    stubFetch(payload)

    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.textContent).toContain('지지 무효화 · support retraction')
    })
    expect(container.textContent).toContain('파생 · 증명 1')
    expect(container.textContent).toContain(missing)
  })

  it('renders current and removed payloads separately when one identity changes metadata', async () => {
    const payload = turnRecordsPayload()
    const added = payload.memory_os.change.added[0]!
    const removed = payload.memory_os.change.removed[0]!
    Object.assign(removed, {
      memory_id: added.memory_id,
      claim: added.claim,
    })
    stubFetch(payload)

    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )

    await waitFor(() => {
      const matching = [...container.querySelectorAll('.mem-store-row')]
        .filter(row => row.querySelector('.mem-store-text')?.textContent === added.claim)
      expect(matching).toHaveLength(2)
      expect(matching.map(row => row.classList.contains('removed'))).toEqual([false, true])
    })
  })

  it('mounts the last captured prompt for the bound keeper from the recall chain', async () => {
    stubFetch()
    promptApi.fetchKeeperLastPrompt.mockResolvedValue({
      keeper: keeper.id,
      capturedAt: 1_700_000_100,
      traceId: 'trace-recall',
      absoluteTurn: 7,
      blocks: [{ id: 'Memory_os_recall', bytes: 800, text: 'recalled: 계속 유지할 핵심 기억' }],
      assembled: null,
    })
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )
    const toggle = await waitFor(() => {
      const button = container.querySelector('.mem-prompt-toggle')
      expect(button).not.toBeNull()
      return button as HTMLButtonElement
    })
    expect(toggle.textContent).toBe('마지막 캡처 보기')
    expect(promptApi.fetchKeeperLastPrompt).not.toHaveBeenCalled()

    fireEvent.click(toggle)

    await waitFor(() => {
      expect(container.textContent).toContain('Memory_os_recall')
    })
    expect(promptApi.fetchKeeperLastPrompt).toHaveBeenCalledTimes(1)
    expect(promptApi.fetchKeeperLastPrompt.mock.calls[0]?.[0]).toBe(keeper.id)
    expect(container.textContent).toContain('trace-recall')
    expect(container.textContent).not.toContain('raw text not persisted')
    expect(toggle.textContent).toBe('마지막 캡처 닫기')
  })

  it('shows a contract error instead of rendering a retired Memory payload', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.memory_os.facts, { expired: 0 })
    stubFetch(payload)
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.textContent).toContain('유효하지 않은 keeper turn record payload')
    })
    expect(container.textContent).not.toContain('계속 유지할 핵심 기억')
  })

  it('renders unavailable content attribution separately from an observed empty input', async () => {
    const payload = turnRecordsPayload()
    Object.assign(payload.entries[0]?.record ?? {}, { input_components: null })
    stubFetch(payload)
    const { container } = render(
      html`<${MemoryInspector} keeper=${keeper} keepers=${[keeper]} onClose=${vi.fn()} />`,
    )

    await waitFor(() => {
      expect(container.textContent).toContain(
        'content 구성 관측 불가 — 빈 입력으로 간주하지 않습니다.',
      )
    })
    expect(container.textContent).toContain('547.4KB wire')
  })
})

describe('MemoryInspector pure projections', () => {
  const row = (
    turn: number,
    blocks: TurnRecordRow['record']['blocks'],
    inputComponents: TurnRecordRow['record']['input_components'] = [],
  ): TurnRecordRow => ({
    record: {
      execution_ids: [],
      keeper: 'keeper',
      agent_name: 'keeper-keeper-agent',
      generation: 1,
      turn_kind: 'autonomous',
      raw_trace_run_ref: null,
      trace_id: 'trace',
      absolute_turn: turn,
      turn_ref: `trace#${turn}`,
      blocks,
      input_components: inputComponents,
      request_runtime_profile: null,
      request_body_bytes: null,
      runtime_profile: 'local',
      ts: turn,
    },
    diff_vs_prev: null,
  })

  it('formats measured bytes and tokens', () => {
    expect(memFmtTok(115_100)).toBe('115.1k')
    expect(memFmtTok(-110_600)).toBe('−110.6k')
    expect(memFmtBytes(1_536)).toBe('1.5KB')
  })

  it('keeps prompt and final-input composition as separate measured views', () => {
    expect(memCompositionFromBlocks([
      { block: 'keeper_instructions', bytes: 1_200, digest: 'a' },
      { block: 'memory_os_recall', bytes: 800, digest: 'b' },
      { block: 'temporal_summary', bytes: 0, digest: 'c' },
    ])).toMatchObject({
      totalBytes: 2_000,
      parts: [{ key: 'keeper_instructions' }, { key: 'memory_os_recall' }],
    })
    expect(memCompositionFromInputComponents([
      { component: 'tool_schemas', bytes: 64_000 },
      { component: 'message_tool_result', bytes: 2_800 },
    ])).toMatchObject({
      totalBytes: 66_800,
      parts: [{ key: 'tool_schemas' }, { key: 'message_tool_result' }],
    })
  })

  it('selects the latest real assembly and recall injection without fabrication', () => {
    const assembled = row(1, [
      { block: 'memory_os_recall', bytes: 100, digest: 'digest-1' },
    ], [{ component: 'prompt.memory_os_recall', bytes: 100 }])
    const emptyTail = row(2, [])
    expect(latestEntryWithBlocks([assembled, emptyTail])).toBe(assembled)
    expect(latestEntryWithInputComponents([assembled, emptyTail])).toBe(emptyTail)
    expect(recentMemoryRecallInjections([assembled, emptyTail])).toEqual([{
      traceId: 'trace',
      turn: 1,
      ts: 1,
      bytes: 100,
      digest: 'digest-1',
    }])
  })

  it('keeps a typed wire-only refusal visible with its exact runtime', () => {
    const content = row(
      1,
      [],
      [{ component: 'tool_schemas', bytes: 100 }],
    )
    const refused: TurnRecordRow = {
      ...row(2, []),
      record: {
        ...row(2, []).record,
        request_runtime_profile: 'anthropic.fallback',
        request_body_bytes: 1_671_330,
      },
    }

    expect(latestEntryWithInputComponents([content, refused])).toBe(refused)
  })

  it('covers the closed category contract and preserves snapshot order', () => {
    const tags: MemoryOsFact['category']['tag'][] = [
      'code_change',
      'fact',
      'preference',
      'blocker',
      'goal',
      'constraint',
      'validated_approach',
      'lesson',
    ]
    for (const tag of tags) {
      expect(factCategoryMeta({ tag }).lbl.length).toBeGreaterThan(0)
    }
    const mkFact = (memory_id: string, claim: string): MemoryOsFact => ({
      memory_id,
      claim,
      category: { tag: 'fact' },
      first_seen: 1,
      current: true,
      basis: { kind: 'observed' },
    })
    const first = mkFact(memoryId('d'), 'first')
    const second = mkFact(memoryId('e'), 'second')
    expect(sortMemoryFactsForReview([first, second])).toEqual([first, second])
  })

  it('places every store row in the latest revision delta and filters on it', () => {
    const typed = (
      memory_id: string,
      tag: MemoryOsFact['category']['tag'],
      current: boolean,
    ): MemoryOsFact => ({
      memory_id,
      claim: memory_id,
      category: { tag },
      first_seen: 1,
      current,
      basis: { kind: 'observed' },
    })
    const retained = typed(memoryId('a'), 'constraint', true)
    const added = typed(memoryId('b'), 'fact', true)
    const removed = typed(memoryId('c'), 'lesson', false)
    const snapshot: MemoryOsTurnRecordSnapshot = {
      keeper: keeper.id,
      snapshot_store: '.masc/keepers/masc-improver.memory-current.json',
      recall_enabled: true,
      revision: 12,
      updated_at: 1_700_000_000,
      update_source: { kind: 'librarian', trace_id: 'trace-a' },
      read_errors: [],
      facts: { shown: 2, current: 2, items: [retained, added] },
      change: { added: [added], removed: [removed], retained: 1, invalidated: [] },
    }
    const rows = storeRowsFromSnapshot(snapshot)
    expect(rows.map(row => [row.fact.memory_id, row.delta])).toEqual([
      [memoryId('a'), null],
      [memoryId('b'), 'added'],
      [memoryId('c'), 'removed'],
    ])
    const byFilter = (filter: Parameters<typeof storeRowMatches>[1]): string[] =>
      rows.filter((row: StoreRow) => storeRowMatches(row, filter)).map(row => row.fact.memory_id)
    expect(byFilter({ kind: 'all' })).toEqual([memoryId('a'), memoryId('b'), memoryId('c')])
    expect(byFilter({ kind: 'delta' })).toEqual([memoryId('b'), memoryId('c')])
    expect(byFilter({ kind: 'category', tag: 'lesson' })).toEqual([memoryId('c')])
    expect(byFilter({ kind: 'category', tag: 'goal' })).toEqual([])
  })
})
