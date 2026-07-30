// @vitest-environment happy-dom
import { cleanup, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  MemoryInspector,
  factCategoryMeta,
  factSelectionReason,
  latestEntryWithBlocks,
  latestEntryWithInputComponents,
  memCompositionFromBlocks,
  memCompositionFromInputComponents,
  memFmtBytes,
  memFmtTok,
  recentMemoryRecallInjections,
  sortMemoryFactsForReview,
  type MemoryKeeper,
} from './memory-inspector'
import { type MemoryOsFact, type TurnRecordRow } from '../api/dashboard'

const keeper: MemoryKeeper = {
  id: 'masc-improver',
  status: 'run',
}

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
    source: { trace_id: 'trace-a', turn: 7 },
    first_seen: 1_700_000_000,
    first_seen_iso: '2023-11-14T22:13:20Z',
    reference_time: 1_700_000_000,
    last_verified_at: null,
    current,
  }
}

function turnRecordsPayload() {
  const retained = fact('id:retained', '계속 유지할 핵심 기억', true, 'constraint')
  const added = fact('id:added', '이번 revision에 새로 들어온 기억', true)
  const removed = fact('id:removed', '이번 revision에서 사라진 기억', false, 'lesson')
  return {
    keeper: keeper.id,
    count: 1,
    skipped_rows: 0,
    source: 'turn_record',
    producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
    durable_store: '.masc/keepers/masc-improver/turn-records',
    dashboard_surface: '/api/v1/keepers/:name/turn-records',
    freshness_slo_s: 300,
    latest_ts_unix: 1_700_000_000,
    latest_ts_iso: '2023-11-14T22:13:20Z',
    latest_age_s: 10,
    health: 'ok',
    stale_reason: null,
    memory_os: {
      schema: 'keeper.memory_os.current_observability.v1',
      keeper: keeper.id,
      source: 'current_memory_snapshot',
      producer: 'keeper_librarian',
      snapshot_store: '.masc/keepers/masc-improver.memory.json',
      recall_enabled: true,
      revision: 12,
      updated_at: 1_700_000_000,
      summary: '현재 작업에 필요한 기억.',
      update_source: {
        kind: 'librarian',
        trace_id: 'trace-a',
        generation: 12,
      },
      now: 1_700_000_000,
      now_iso: '2023-11-14T22:13:20Z',
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
      },
    },
    entries: [{
      record: {
        execution_ids: [],
        keeper: keeper.id,
        trace_id: 'trace-a',
        absolute_turn: 7,
        turn_ref: 'trace-a#7',
        blocks: [
          { block: 'persona', bytes: 1_200, digest: 'aaaa1111bbbb' },
          { block: 'memory_os_recall', bytes: 800, digest: 'cccc2222dddd' },
        ],
        input_components: [
          { component: 'prompt.persona', bytes: 1_200 },
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
  const fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify(payload), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
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
    expect(text).toContain('LLM current-memory choice')
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
      { block: 'persona', bytes: 1_200, digest: 'a' },
      { block: 'memory_os_recall', bytes: 800, digest: 'b' },
      { block: 'temporal_summary', bytes: 0, digest: 'c' },
    ])).toMatchObject({
      totalBytes: 2_000,
      parts: [{ key: 'persona' }, { key: 'memory_os_recall' }],
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
    expect(latestEntryWithInputComponents([assembled, emptyTail])).toBe(assembled)
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
      source: { trace_id: 'trace', turn: 1, tool_call_id: null },
      first_seen: 1,
      first_seen_iso: '1970-01-01T00:00:01Z',
      reference_time: 1,
      last_verified_at: null,
      current: true,
    })
    const first = mkFact('id:first', 'first')
    const second = mkFact('id:second', 'second')
    expect(sortMemoryFactsForReview([first, second])).toEqual([first, second])
    expect(factSelectionReason(first)).toBe('current snapshot · 사실')
  })
})
