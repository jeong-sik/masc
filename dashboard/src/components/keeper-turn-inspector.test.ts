// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperTurnRecords, fetchKeeperTurnTranscript, type TurnRecordsResponse, type TurnTranscript } from '../api/dashboard'
import {
  initialTurnRowForTurnRef,
  KeeperMemoryOsRecallPanel,
  KeeperTurnInspector,
} from './keeper-turn-inspector'

vi.mock('../api/dashboard', () => {
  return {
    fetchKeeperTurnRecords: vi.fn(),
    fetchKeeperTurnTranscript: vi.fn(),
  }
})

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
          turn_ref: 'trace-active#41',
          ts: 1_781_587_500,
          runtime_profile: 'local',
          blocks: [{ block: 'system', bytes: 1200, digest: '1111222233334444' }],
        },
        diff_vs_prev: null,
      },
      {
        record: {
          keeper: 'albini',
          trace_id: 'trace-active',
          absolute_turn: 42,
          turn_ref: 'trace-active#42',
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
    expect(drawerText).toContain('trace-active#42')
    expect(drawerText).toContain('local')
  })

  it('matches the exact opaque turn_ref with no reconstruction or fuzzy fallback', () => {
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

    // Unmatched opaque values return null, never throw.
    expect(initialTurnRowForTurnRef(response.entries, 'no-separator')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, 'trace-active#abc')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, 'trace-active#')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, '#42')).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, null)).toBeNull()
    expect(initialTurnRowForTurnRef(response.entries, undefined)).toBeNull()
    expect(initialTurnRowForTurnRef([], 'trace-active#42')).toBeNull()
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
    expect(container.textContent).toContain('Provider 요청 관측')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-messages"]')?.classList.contains('on')).toBe(true)
    })

    expect(container.textContent).toContain('턴 전사 관측')

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
    // Concepts absent from TurnRecord are not rendered as synthetic metadata.
    expect(meta).not.toContain('namespace')
    expect(meta).not.toContain('fsm.state')
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

    const timeline = container.querySelector('.kti-wf')
    expect(timeline?.querySelectorAll('.kti-wf-row')).toHaveLength(1)
    expect(timeline?.textContent).toContain('Provider request wall-clock')
    expect(container.querySelector('.kti-wf-foot')?.textContent).toContain('1.2s · TTFRC 568ms')
    expect(timeline?.textContent).not.toContain('컨텍스트 조립')
    expect(timeline?.textContent).not.toContain('Thinking')
    expect(timeline?.textContent).not.toContain('응답 생성')
    expect(timeline?.querySelector('[data-testid="turn-provider-latency-observed"]')).toBeTruthy()

    const stats = container.querySelector('[data-testid="turn-summary-stats"]')?.textContent ?? ''
    expect(stats).toContain('Provider')
    // The TurnRecord owns only provider timing. Tool execution observations
    // live in Trajectory and are not copied or joined through this record.
    expect(stats).toContain('1.2s')
    expect(stats).toContain('입력')
    expect(stats).toContain('2,400')
    expect(stats).toContain('출력')
    expect(stats).toContain('280')
    expect(stats).not.toContain('도구')
    // Provider-declared prices are not a measured turn cost. The inspector
    // must not infer and present one as an observation.
    expect(stats).not.toContain('비용')
    expect(stats).not.toContain('$')
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
    expect(text).toContain('2 메시지 · keeper_chat_store')
    expect(text).not.toContain('시스템 프롬프트')
    expect(text).not.toContain('주입 컨텍스트')
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

  it('displays the observed token stacked bar', async () => {
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
    expect(barText).toContain('토큰 관측')
    expect(barText).toContain('입력 2,400')
    expect(barText).toContain('출력 280')
  })

  it('renders absent token and duration observations without estimates or inferred cost', async () => {
    const response = turnRecordsWithMemoryOs()
    const record = response.entries[1]!.record
    delete record.input_tokens
    delete record.output_tokens
    delete record.request_latency_ms
    delete record.ttfrc_ms
    // Keep non-zero block bytes and provider prices: neither may be used to
    // manufacture token usage, turn cost, or phase duration.
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const stats = Array.from(container.querySelectorAll('.kti-stat .v')).map(el => el.textContent)
    expect(stats).toEqual(['측정 없음', '측정 없음', '측정 없음'])
    expect(container.querySelectorAll('.kti-wf-bar')).toHaveLength(0)
    expect(container.querySelector('[data-testid="turn-provider-latency-unmeasured"]')).toBeTruthy()

    const tokenPanel = container.querySelector('[data-testid="turn-token-bar"]')
    expect(tokenPanel?.textContent).toContain('입력 측정 없음')
    expect(tokenPanel?.textContent).toContain('출력 측정 없음')
    expect(tokenPanel?.textContent).toContain('토큰 분할 측정 없음')
    expect(tokenPanel?.querySelector('.seg-in')).toBeNull()
    expect(tokenPanel?.querySelector('.seg-out')).toBeNull()

    expect(container.querySelector('[data-testid="turn-tab-context"]')).toBeNull()

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-transcript-user-absent"]')).toBeTruthy()
    })
    const messages = container.querySelector('.kti-seq-rail')?.textContent ?? ''
    expect(messages).not.toContain('시스템 프롬프트')
    expect(messages).not.toContain('주입 컨텍스트')
    expect(messages).not.toContain('85%')
    expect(messages).not.toContain('compact()')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)
    const meta = container.querySelector('.kti-kv')?.textContent ?? ''
    expect(meta).toContain('input tokens측정 없음')
    expect(meta).toContain('output tokens측정 없음')
    expect(meta).toContain('provider request wall-clock측정 없음')
    expect(meta).toContain('time to first response chunk측정 없음')
    expect(meta).not.toContain('cost')
    expect(meta).not.toContain('$')
  })

  it('preserves TTFRC when provider request wall-clock is absent', async () => {
    const response = turnRecordsWithMemoryOs()
    delete response.entries[1]!.record.request_latency_ms
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })
    fireEvent.click(container.querySelector('.kti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-provider-latency-unmeasured"]')).toBeTruthy()
    })
    const timelineText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(timelineText).toContain('request wall-clock 측정 없음')
    expect(timelineText).toContain('TTFRC 568ms')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)
    const meta = container.querySelector('.kti-kv')?.textContent ?? ''
    expect(meta).toContain('provider request wall-clock측정 없음')
    expect(meta).toContain('time to first response chunk568ms')
  })

  it('copies the exact turn_ref when the copy button is clicked', async () => {
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
    // The drawer header copies the exact opaque join key, without rebuilding it.
    fireEvent.click(copyButtons[0]!)

    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith('trace-active#42')
    })
  })

  it('surfaces clipboard failure instead of failing silently', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    vi.mocked(navigator.clipboard.writeText).mockRejectedValueOnce(new Error('denied'))

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })
    fireEvent.click(container.querySelector('.kti-turn-summary')!)
    fireEvent.click(container.querySelector('.kti-copy')!)

    await waitFor(() => {
      expect(container.querySelector('.kti-copy.failed')?.textContent).toContain('복사 실패')
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
