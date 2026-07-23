// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperToolCalls, fetchKeeperTurnRecords, fetchKeeperTurnTranscript, type ToolCallsResponse, type TurnRecordsResponse, type TurnTranscript } from '../api/dashboard'
import {
  initialTurnRowForTimestamp,
  initialTurnRowForTurnRef,
  KeeperMemoryOsRecallPanel,
  KeeperTurnInspector,
} from './keeper-turn-inspector'

vi.mock('../api/dashboard', () => {
  return {
    fetchKeeperToolCalls: vi.fn(),
    fetchKeeperTurnRecords: vi.fn(),
    fetchKeeperTurnTranscript: vi.fn(),
  }
})

const fetchKeeperToolCallsMock = vi.mocked(fetchKeeperToolCalls)
const fetchKeeperTurnRecordsMock = vi.mocked(fetchKeeperTurnRecords)
const fetchKeeperTurnTranscriptMock = vi.mocked(fetchKeeperTurnTranscript)

function emptyTranscript(): TurnTranscript {
  return {
    keeper: 'albini',
    turn_ref: 'trace-active#42',
    found: false,
    source: 'keeper_chat_store',
    user: [],
    assistant: [],
  }
}

function transcriptForTurn(): TurnTranscript {
  return {
    keeper: 'albini',
    turn_ref: 'trace-active#42',
    found: true,
    source: 'keeper_chat_store',
    user: [{ role: 'user', content: 'deploy the staging build', ts: 1_781_587_540 }],
    assistant: [{ role: 'assistant', content: 'staging build deployed', ts: 1_781_587_560 }],
  }
}

function emptyToolCalls(): ToolCallsResponse {
  return {
    source: 'tool_call_io',
    health: 'ok',
    keeper: 'albini',
    count: 0,
    entries: [],
  }
}

function toolCallsForTurn(): ToolCallsResponse {
  return {
    source: 'tool_call_io',
    health: 'ok',
    keeper: 'albini',
    count: 1,
    entries: [
      {
        ts: 1_781_587_556,
        keeper: 'albini',
        tool: 'keeper_board_post_get',
        input: { post_id: 'p-1' },
        output: 'ok',
        success: true,
        duration_ms: 54,
        trace_id: 'trace-active',
        session_id: 'trace-active',
        turn: 9001,
        keeper_turn_id: 42,
        execution_id: 'exec-42',
        tool_use_id: 'tool-use-42',
      },
    ],
  }
}

function turnRecordsWithMemoryOs(): TurnRecordsResponse {
  return {
    source: 'turn_record',
    health: 'ok',
    keeper: 'albini',
    count: 2,
    skipped_rows: 0,
    memory_os: {
      schema: 'masc.memory_os.dashboard.v1',
      keeper: 'albini',
      source: 'memory_os',
      producer: 'keeper_memory_os.recall',
      selection_policy: null,
      facts_store: '.masc/config/keepers/albini.facts.jsonl',
      episodes_store: '.masc/config/keepers/albini/episodes',
      recall_enabled: true,
      now: 1_781_587_600,
      now_iso: '2026-06-16T02:00:00Z',
      read_errors: [],
      episodes: {
        shown: 2,
        current: 1,
        expired: 1,
        terminal_markers: 1,
        items: [
          {
            trace_id: 'trace-active',
            generation: 7,
            created_at: 1_781_583_000,
            created_at_iso: '2026-06-16T00:43:20Z',
            valid_until: 1_781_590_000,
            valid_until_iso: '2026-06-16T02:40:00Z',
            current: true,
            terminal_marker: null,
            claim_count: 2,
            source_turn_range: [1, 6],
            summary: 'Active recall source used by the prompt.',
          },
          {
            trace_id: 'trace-done',
            generation: 3,
            created_at: 1_781_580_000,
            created_at_iso: '2026-06-15T23:53:20Z',
            valid_until: 1_781_585_400,
            valid_until_iso: '2026-06-16T01:23:20Z',
            current: false,
            terminal_marker: 'handoff_complete',
            claim_count: 1,
            source_turn_range: null,
            summary: 'Terminal memory should stay visible as expired source evidence.',
          },
        ],
      },
      facts: {
        shown: 9,
        current: 8,
        expired: 1,
        items: [],
      },
    },
    entries: [
      {
        record: {
          keeper: 'albini',
          trace_id: 'trace-active',
          absolute_turn: 41,
          ts: 1_781_587_500,
          runtime_profile: 'local',
          blocks: [{ block: 'system', bytes: 1200, digest: '1111222233334444' }],
          execution_ids: [],
        },
        diff_vs_prev: null,
      },
      {
        record: {
          keeper: 'albini',
          trace_id: 'trace-active',
          absolute_turn: 42,
          ts: 1_781_587_560,
          runtime_profile: 'local',
          model: 'deepseek-v4-flash',
          finish_reason: 'completed',
          input_tokens: 2400,
          output_tokens: 280,
          context_window: 203000,
          price_input_per_million: 0.27,
          price_output_per_million: 1.1,
          request_latency_ms: 1234,
          ttfrc_ms: 567.8,
          blocks: [
            { block: 'system', bytes: 1200, digest: '1111222233334444' },
            { block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' },
          ],
          execution_ids: ['exec-42'],
        },
        diff_vs_prev: {
          added: [
            { block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' },
          ],
          removed: [],
          changed: [],
        },
      },
    ],
  }
}

function toolCallsForTurnWithoutDuration(): ToolCallsResponse {
  const response = toolCallsForTurn()
  return {
    ...response,
    entries: response.entries.map(entry => ({
      ...entry,
      duration_ms: null,
    })),
  }
}

beforeEach(() => {
  fetchKeeperToolCallsMock.mockResolvedValue(emptyToolCalls())
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('KeeperMemoryOsRecallPanel', () => {
  it('surfaces Memory OS recall blocks and episode TTL evidence', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperMemoryOsRecallPanel} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="memory-os-recall-source"]')).toBeTruthy()
    })

    expect(fetchKeeperTurnRecordsMock).toHaveBeenCalledWith(
      'albini',
      12,
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    const text = container.textContent ?? ''
    expect(text).toContain('Memory OS recall')
    expect(text).toContain('enabled')
    expect(text).toContain('latest block')
    expect(text).toContain('3392B')
    expect(text).toContain('ep 1/2')
    expect(text).toContain('expired 1')
    expect(text).toContain('terminal 1')
    expect(text).toContain('facts 8/9')
    expect(text).toContain('terminal=handoff_complete')
    expect(text).toContain('expired 2026-06-16 01:23:20Z')
    expect(text).toContain('facts: .masc/config/keepers/albini.facts.jsonl')
    expect(text).toContain('episodes: .masc/config/keepers/albini/episodes')
  })

  it('shows a source-missing state when the API has no Memory OS snapshot', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue({
      source: 'turn_record',
      health: 'ok',
      keeper: 'albini',
      count: 0,
      skipped_rows: 0,
      memory_os: null,
      entries: [],
    })

    const { container } = render(html`<${KeeperMemoryOsRecallPanel} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('Memory OS recall source 없음')
    })
  })
})

describe('KeeperTurnInspector v2 drawer', () => {
  beforeEach(() => {
    fetchKeeperToolCallsMock.mockResolvedValue(toolCallsForTurn())
    fetchKeeperTurnTranscriptMock.mockResolvedValue(emptyTranscript())
    Object.defineProperty(navigator, 'clipboard', {
      value: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
      writable: true,
      configurable: true,
    })
  })

  it('renders the detail drawer when a turn row is clicked', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    const summary = container.querySelector('.kti-turn-summary')
    expect(summary).toBeTruthy()
    fireEvent.click(summary!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(drawerText).toContain('턴 상세')
    expect(drawerText).toContain('trace-active_0042')
    expect(drawerText).toContain('local')
  })

  it('matches an initial timestamp to the closest retained turn row', () => {
    const response = turnRecordsWithMemoryOs()
    const nearTurn42 = new Date((1_781_587_560 + 12) * 1000).toISOString()
    const farFromRetainedTurns = new Date((1_781_587_560 + 3600) * 1000).toISOString()

    expect(initialTurnRowForTimestamp(response.entries, nearTurn42)?.record.absolute_turn).toBe(42)
    expect(initialTurnRowForTimestamp(response.entries, farFromRetainedTurns)).toBeNull()
    expect(initialTurnRowForTimestamp(response.entries, 'not-a-date')).toBeNull()
  })

  it('matches an exact turn_ref (trace_id + absolute_turn), no fuzzy fallback', () => {
    const response = turnRecordsWithMemoryOs()

    // Exact key hits the precise row, not the nearest by time.
    expect(
      initialTurnRowForTurnRef(response.entries, 'trace-active#42')?.record.absolute_turn,
    ).toBe(42)
    expect(
      initialTurnRowForTurnRef(response.entries, 'trace-active#41')?.record.absolute_turn,
    ).toBe(41)

    // A present-but-unmatched key returns null (never a window guess).
    expect(initialTurnRowForTurnRef(response.entries, 'trace-active#999')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, 'trace-other#42')).toBeNull()

    // Malformed keys decode to null, never throw.
    expect(initialTurnRowForTurnRef(response.entries, 'no-separator')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, 'trace-active#abc')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, 'trace-active#')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, '#42')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, null)).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, undefined)).toBeNull()
    expect(initialTurnRowForTurnRef([], 'trace-active#42')).toBeNull()
  })

  it('opens the detail drawer when an initial timestamp matches a retained turn', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    const nearTurn42 = new Date((1_781_587_560 + 12) * 1000).toISOString()

    const { container } = render(html`
      <${KeeperTurnInspector}
        keeperName="albini"
        initialTurnTimestamp=${nearTurn42}
      />
    `)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(drawerText).toContain('trace-active_0042')
    expect(container.querySelector('[data-testid="turn-linked-empty"]')).toBeFalsy()
  })

  it('keeps the list view when an initial timestamp is outside the retained turn window', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    const farFromRetainedTurns = new Date((1_781_587_560 + 3600) * 1000).toISOString()

    const { container } = render(html`
      <${KeeperTurnInspector}
        keeperName="albini"
        initialTurnTimestamp=${farFromRetainedTurns}
      />
    `)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-linked-empty"]')).toBeTruthy()
    })
    expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeFalsy()
    expect(container.textContent).toContain('30분 이내의 turn record 없음')
  })

  it('renders repeated trace turn rows without duplicate-key warnings', async () => {
    const response = turnRecordsWithMemoryOs()
    response.entries = [
      ...response.entries,
      {
        record: {
          ...response.entries[1]!.record,
          ts: 1_781_587_620,
          output_tokens: 312,
          execution_ids: ['exec-42b'],
        },
        diff_vs_prev: null,
      },
    ]
    response.count = response.entries.length
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)

    try {
      const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

      await waitFor(() => {
        expect(container.querySelectorAll('.kti-turn-summary').length).toBe(3)
      })

      const duplicateKeyCalls = errorSpy.mock.calls
        .flat()
        .map(value => String(value))
        .filter(value => value.includes('same key') || value.includes('same key attribute'))
      expect(duplicateKeyCalls).toEqual([])
    } finally {
      errorSpy.mockRestore()
    }
  })

  it('switches tabs inside the drawer', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-messages"]')).toBeTruthy()
    })

    expect(container.querySelector('[data-testid="turn-tab-timeline"]')?.classList.contains('on')).toBe(true)
    expect(container.textContent).toContain('턴 워터폴')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-messages"]')?.classList.contains('on')).toBe(true)
    })

    expect(container.textContent).toContain('모델에 전달된 시퀀스')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })
  })

  it('renders the tab rail as a pill tablist with exactly one active pill', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-timeline"]')).toBeTruthy()
    })

    // The pill rail container is the tablist styled by .kti-tabs.
    const rail = container.querySelector('.kti-tabs')
    expect(rail).toBeTruthy()
    expect(rail?.getAttribute('role')).toBe('tablist')

    // Every tab is a .kti-tab pill (the class the CSS pill rule targets),
    // and the rail holds more than one pill so the gap/flex layout applies.
    const pills = rail!.querySelectorAll('.kti-tab')
    expect(pills.length).toBeGreaterThan(1)
    pills.forEach((pill) => {
      expect(pill.classList.contains('kti-tab')).toBe(true)
      expect(pill.getAttribute('role')).toBe('tab')
    })

    // Exactly one pill carries the active `.kti-tab.on` class (the volt-wash
    // fill state), and it is the timeline tab by default.
    const activePills = rail!.querySelectorAll('.kti-tab.on')
    expect(activePills.length).toBe(1)
    expect(activePills[0]?.getAttribute('data-testid')).toBe('turn-tab-timeline')
    expect(activePills[0]?.getAttribute('aria-selected')).toBe('true')

    // Switching tabs moves the single active pill, never duplicates it.
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      const nextActive = rail!.querySelectorAll('.kti-tab.on')
      expect(nextActive.length).toBe(1)
      expect(nextActive[0]?.getAttribute('data-testid')).toBe('turn-tab-meta')
    })
    expect(
      container.querySelector('[data-testid="turn-tab-timeline"]')?.classList.contains('on'),
    ).toBe(false)
  })

  it('grounds model / finish_reason from the record and marks deferred fields n/a', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })

    const meta = container.querySelector('.kti-kv')?.textContent ?? ''
    // grounded from the backend turn record (RFC-0233 §2.3)
    expect(meta).toContain('deepseek-v4-flash')
    expect(meta).toContain('completed')
    // finish_reason is no longer the fabricated hardcoded 'stop'
    expect(meta).not.toContain('stop')
    // fsm.state is not captured in MASC — honest absence, rendered as n/a. namespace
    // was removed entirely: the concept is absent from the turn record, so it is no
    // longer shown as a fabricated n/a field (keeper-v2 turn-inspector delta).
    expect(meta).not.toContain('namespace')
    expect(meta).toContain('fsm.state')
    expect(meta).toContain('n/a')
  })

  it('renders finish_reason absence as n/a without fabricating a value', async () => {
    const response = turnRecordsWithMemoryOs()
    // strip the grounded meta fields → simulate an error turn / pre-grounding row
    response.entries[1] = {
      ...response.entries[1]!,
      record: {
        ...response.entries[1]!.record,
        model: undefined,
        finish_reason: undefined,
      },
    }
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })

    const meta = container.querySelector('.kti-kv')?.textContent ?? ''
    expect(meta).not.toContain('stop')
    expect(meta).not.toContain('deepseek-v4-flash')
    expect(meta).toContain('n/a')
  })

  it.each([
    { enableThinking: true, expected: 'on' },
    { enableThinking: false, expected: 'off' },
    { enableThinking: undefined, expected: '—' },
  ] as Array<{ enableThinking: boolean | undefined; expected: string }>)(
    'renders sampling params from the record without fabricating top_p/max_tokens ($expected)',
    async ({ enableThinking, expected }) => {
      const response = turnRecordsWithMemoryOs()
      response.entries[1] = {
        ...response.entries[1]!,
        record: {
          ...response.entries[1]!.record,
          temperature: 0.7,
          top_p: enableThinking === undefined ? undefined : 0.9,
          max_tokens: enableThinking === undefined ? undefined : 8192,
          thinking_budget: 2048,
          enable_thinking: enableThinking,
        },
      }
      fetchKeeperTurnRecordsMock.mockResolvedValue(response)

      const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

      await waitFor(() => {
        expect(container.textContent).toContain('T42')
      })

      fireEvent.click(container.querySelector('.kti-turn-summary')!)
      fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

      await waitFor(() => {
        expect(container.textContent).toContain('샘플링 파라미터')
      })

      const params = Array.from(container.querySelectorAll('.kti-param')).map(el => el.textContent ?? '')
      expect(params).toContain('temperature0.7')
      if (enableThinking === undefined) {
        expect(params).toContain('top_p—')
        expect(params).toContain('max_tokens—')
        expect(params).toContain('thinking_budget2048')
      } else {
        expect(params).toContain('top_p0.9')
        expect(params).toContain('max_tokens8,192')
        expect(params).toContain('thinking_budget2048')
      }
      expect(params).toContain(`enable_thinking${expected}`)
      // fabricated defaults must not appear as chips
      expect(params).not.toContain('top_p0.95')
      expect(params).not.toContain('max_tokens4,096')
    },
  )
  it('displays summary stats in the stat strip', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-summary-stats"]')).toBeTruthy()
    })

    const stats = container.querySelector('[data-testid="turn-summary-stats"]')?.textContent ?? ''
    expect(stats).toContain('실측')
    // RFC-0233 §9: the gen phase's request_latency_ms (1234ms) joins the tool
    // duration (54ms) in the measured-total, so the strip reflects the
    // provider call wall-clock too (1234 + 54 = 1288ms → "1.3s"). This is the
    // sum of measured phases, not the turn wall-clock — see §9.4.
    expect(stats).toContain('1.3s')
    expect(stats).toContain('입력')
    expect(stats).toContain('2.4k')
    expect(stats).toContain('출력')
    expect(stats).toContain('280')
    expect(stats).toContain('도구')
    expect(stats).toContain('1')
    expect(stats).toContain('추정비용')
    // RFC-0233 §8: turn 42 fixture carries real context_window + prices, so
    // the nullable ctxPct/cost render grounded values — not "미상". Guards the
    // number|null widening against a regression that drops the grounded path.
    expect(stats).not.toContain('미상')
  })

  it('joins tool-call duration and agent subturn by execution_id', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(fetchKeeperToolCallsMock).toHaveBeenCalledWith(
      'albini',
      200,
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    expect(drawerText).toContain('keeper turn')
    expect(drawerText).toContain('agent subturns')
    expect(drawerText).toContain('T9001')
    expect(drawerText).toContain('keeper_board_post_get')
    // RFC-0233 §9/§10: the gen (response-generation) phase carries
    // request_latency_ms from the record (1234ms → "1.2s") plus ttfrc_ms
    // (567.8ms → "568ms"), so it renders a measured duration with the
    // time-to-first-token instead of "측정 없음".
    expect(drawerText).toContain('1.2s')
    expect(drawerText).toContain('첫 568ms')
    expect(drawerText).toContain('54ms')
    expect(drawerText).not.toContain('0.50s')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('agent subturn T9001')
    })
  })

  it('keeps joined tool calls with missing duration unmeasured, not 0ms', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperToolCallsMock.mockResolvedValue(toolCallsForTurnWithoutDuration())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(drawerText).toContain('keeper_board_post_get')
    expect(drawerText).toContain('측정 없음')
    expect(drawerText).not.toContain('0ms')
    expect(drawerText).not.toContain('0.50s')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('duration 없음')
    })
  })

  it('renders real tool call input and output in the messages tab (RFC-0233)', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      const text = container.textContent ?? ''
      // Real tool I/O joined from the tool-call log by execution_id.
      expect(text).toContain('요청 · input')
      expect(text).toContain('응답 · result')
      expect(text).toContain('post_id')
      expect(text).toContain('p-1')
    })
    const text = container.textContent ?? ''
    // The deferred placeholders must be gone.
    expect(text).not.toContain('도구 결과는 별도 execution trace 에서 확인')
  })

  it('renders explicit tool I/O absence when no tool-call entry matches the execution (RFC-0233)', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    // execution_id 'exec-42' on the record has no matching tool-call entry.
    fetchKeeperToolCallsMock.mockResolvedValue(emptyToolCalls())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tool-io-absent"]')).toBeTruthy()
    })
    // No fabricated result text.
    expect(container.textContent ?? '').not.toContain('응답 · result')
  })

  it('renders the real operator request and keeper response from the transcript (RFC-0233 §7)', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperTurnTranscriptMock.mockResolvedValue(transcriptForTurn())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    // Transcript is fetched lazily for the open turn's join key.
    expect(fetchKeeperTurnTranscriptMock).toHaveBeenCalledWith(
      'albini',
      'trace-active#42',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-transcript-user"]')?.textContent ?? '').toContain(
        'deploy the staging build',
      )
    })
    expect(container.querySelector('[data-testid="turn-transcript-assistant"]')?.textContent ?? '').toContain(
      'staging build deployed',
    )
    const text = container.textContent ?? ''
    expect(text).not.toContain('직전 operator 요청 — 본 대화의 사용자 메시지')
    expect(text).not.toContain('keeper 응답 — 본 턴의 출력 메시지')
  })

  it('renders explicit transcript absence when the turn has no joinable rows (RFC-0233 §7)', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperTurnTranscriptMock.mockResolvedValue(emptyTranscript())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-transcript-user-absent"]')).toBeTruthy()
    })
    expect(container.querySelector('[data-testid="turn-transcript-assistant-absent"]')).toBeTruthy()
  })

  it('warns when the timing source fails while keeping turn records visible', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperToolCallsMock.mockRejectedValue(new Error('tool log unavailable'))

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.textContent).toContain('tool-call timing source unavailable')

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(drawerText).toContain('tool-call timing source unavailable')
    expect(drawerText).toContain('tool log unavailable')
  })

  it('displays the token-economics stacked bar', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-token-bar"]')).toBeTruthy()
    })

    const barText = container.querySelector('[data-testid="turn-token-bar"]')?.textContent ?? ''
    expect(barText).toContain('토큰 경제')
    expect(barText).toContain('입력 2,400')
    expect(barText).toContain('출력 280')
  })

  it('copies the trace id when the copy button is clicked', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('.kti-copy')).toBeTruthy()
    })

    const copyButtons = container.querySelectorAll('.kti-copy')
    // First copy button is the trace-id copy in the header.
    fireEvent.click(copyButtons[0]!)

    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith('trace-active_0042')
    })
  })

  it('closes the drawer on escape key', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.keyDown(window, { key: 'Escape' })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeFalsy()
    })
  })
})
