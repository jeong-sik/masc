// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperTurnRecords, type TurnRecordsResponse } from '../api/dashboard'
import {
  initialTurnRowForTimestamp,
  initialTurnRowForTurnRef,
  KeeperMemoryOsRecallPanel,
  KeeperTurnInspector,
} from './keeper-turn-inspector'

vi.mock('../api/dashboard', () => {
  return {
    fetchKeeperTurnRecords: vi.fn(),
  }
})

const fetchKeeperTurnRecordsMock = vi.mocked(fetchKeeperTurnRecords)

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
      facts_store: '.masc/config/keepers/albini.facts.jsonl',
      episodes_store: '.masc/config/keepers/albini/episodes',
      recall_enabled: true,
      now: 1_781_587_600,
      now_iso: '2026-06-16T02:00:00Z',
      read_errors: [],
      episodes: {
        tail_limit: 12,
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
            summary: 'Terminal memory should stay visible as expired source evidence.',
          },
        ],
      },
      facts: {
        tail_limit: 256,
        shown: 9,
        current: 8,
        expired: 1,
      },
    },
    user_model: {
      schema: 'keeper.user_model.dashboard.v1',
      keeper: 'albini',
      source: 'memory_os_facts',
      producer: 'keeper_user_model',
      facts_store: '.masc/config/keepers/albini.facts.jsonl',
      shared_facts_store: '.masc/config/keepers/_shared.facts.jsonl',
      enabled: true,
      now: 1_781_587_600,
      now_iso: '2026-06-16T02:00:00Z',
      read_errors: [],
      source_fact_count: 6,
      shared_fact_count: 2,
      preferences: [
        {
          claim: 'User prefers concise answers',
          category: 'preference',
          source: 'keeper',
          observed_by: [],
          turn: 10,
          first_seen: 1_781_580_000,
          first_seen_iso: '2026-06-15T23:53:20Z',
          last_verified_at: 1_781_587_000,
          last_verified_at_iso: '2026-06-16T01:50:00Z',
        },
      ],
      constraints: [
        {
          claim: 'Let CI be the authority for full builds',
          category: 'constraint',
          source: 'shared',
          observed_by: ['qa-king', 'verifier'],
          turn: 14,
          first_seen: 1_781_581_000,
          first_seen_iso: '2026-06-16T00:10:00Z',
          last_verified_at: 1_781_587_100,
          last_verified_at_iso: '2026-06-16T01:51:40Z',
        },
      ],
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
          input_tokens: 2400,
          output_tokens: 280,
          blocks: [
            { block: 'system', bytes: 1200, digest: '1111222233334444' },
            { block: 'user_model', bytes: 728, digest: '99887766554433221100' },
            { block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' },
          ],
          execution_ids: ['exec-42'],
        },
        diff_vs_prev: {
          added: [
            { block: 'user_model', bytes: 728, digest: '99887766554433221100' },
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

  it('surfaces user-model preferences and constraints from turn records', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="user-model-source"]')).toBeTruthy()
    })

    const text = container.textContent ?? ''
    expect(text).toContain('User model')
    expect(text).toContain('enabled')
    expect(text).toContain('latest block')
    expect(text).toContain('728B')
    expect(text).toContain('pref 1')
    expect(text).toContain('constraints 1')
    expect(text).toContain('facts 6')
    expect(text).toContain('shared 2')
    expect(text).toContain('User prefers concise answers')
    expect(text).toContain('Let CI be the authority for full builds')
    expect(text).toContain('shared via qa-king,verifier')
    expect(text).toContain('shared: .masc/config/keepers/_shared.facts.jsonl')
  })

  it('shows a source-missing state when the API has no Memory OS snapshot', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue({
      source: 'turn_record',
      health: 'ok',
      keeper: 'albini',
      count: 0,
      skipped_rows: 0,
      memory_os: null,
      user_model: null,
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
    expect(stats).toContain('소요')
    expect(stats).toContain('입력')
    expect(stats).toContain('2.4k')
    expect(stats).toContain('출력')
    expect(stats).toContain('280')
    expect(stats).toContain('도구')
    expect(stats).toContain('1')
    expect(stats).toContain('추정비용')
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
