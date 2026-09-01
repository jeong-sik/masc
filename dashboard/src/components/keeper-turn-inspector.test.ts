// @vitest-environment happy-dom
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  fetchKeeperProviderInput,
  fetchKeeperToolCalls,
  fetchKeeperTurnRecords,
  type ProviderInputSnapshot,
  type ToolCallsResponse,
  type TurnRecordsResponse,
} from '../api/dashboard'
import {
  initialTurnRowForTimestamp,
  initialTurnRowForTurnRef,
  KeeperMemoryOsRecallPanel,
  KeeperTurnInspector,
} from './keeper-turn-inspector'

vi.mock('../api/dashboard', () => {
  return {
    fetchKeeperProviderInput: vi.fn(),
    fetchKeeperToolCalls: vi.fn(),
    fetchKeeperTurnRecords: vi.fn(),
  }
})

const fetchKeeperProviderInputMock = vi.mocked(fetchKeeperProviderInput)
const fetchKeeperToolCallsMock = vi.mocked(fetchKeeperToolCalls)
const fetchKeeperTurnRecordsMock = vi.mocked(fetchKeeperTurnRecords)

function providerInputForTurn(): ProviderInputSnapshot {
  return {
    keeper: 'albini',
    traceId: 'trace-active',
    absoluteTurn: 42,
    turnRef: 'trace-active#42',
    runtimeProfile: 'local',
    capturedAt: 1_781_587_559,
    wire: {
      phase: 'Pre_dispatch_serialization',
      captureId: 'capture-42',
      provider: 'deepseek',
      model: 'deepseek-v4-flash',
      httpCodec: 'openai-compatible',
      stream: true,
      bodyBytes: 560_513,
      bodySha256: 'a'.repeat(64),
    },
    systemPrompt: {
      bytes: 25,
      sha256: 'b'.repeat(64),
      text: 'exact system prompt T42',
    },
    messages: [
      {
        index: 0,
        role: 'user',
        bytes: 58,
        sha256: 'c'.repeat(64),
        content: { role: 'user', content: 'deploy the staging build' },
      },
      {
        index: 1,
        role: 'assistant',
        bytes: 65,
        sha256: 'd'.repeat(64),
        content: { role: 'assistant', content: 'previous keeper reply' },
      },
      {
        index: 2,
        role: 'tool',
        bytes: 96,
        sha256: 'e'.repeat(64),
        content: { role: 'tool', content: 'large tool result retained in this turn' },
      },
    ],
    toolSchemas: [
      {
        index: 0,
        name: 'masc_board_post_get',
        bytes: 87,
        sha256: 'f'.repeat(64),
        content: {
          name: 'masc_board_post_get',
          description: 'read a board post',
          input_schema: { type: 'object' },
        },
      },
    ],
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
        tool: 'masc_board_post_get',
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
    producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
    durable_store: '.masc/keepers/albini/turn-records',
    dashboard_surface: '/api/v1/keepers/:name/turn-records',
    freshness_slo_s: 300,
    live_turn_in_progress: false,
    live_turn_started_at_unix: null,
    live_turn_last_progress_at_unix: null,
    latest_ts_unix: 1_781_587_560,
    latest_ts_iso: '2026-06-16T05:26:00Z',
    latest_age_s: 40,
    health: 'ok',
    stale_reason: null,
    keeper: 'albini',
    count: 2,
    skipped_rows: 0,
    memory_os: {
      keeper: 'albini',
      snapshot_store: '.masc/config/keepers/albini.memory-current.json',
      recall_enabled: true,
      revision: 7,
      updated_at: 1_781_587_590,
      update_source: {
        kind: 'librarian',
        trace_id: 'trace-active',
      },
      read_errors: [],
      facts: {
        shown: 1,
        current: 1,
        items: [],
      },
      change: {
        added: [],
        removed: [],
        retained: 1,
        invalidated: [],
      },
    },
    entries: [
      {
        record: {
          keeper: 'albini',
          agent_name: 'keeper-albini-agent',
          generation: 1,
          turn_kind: 'autonomous',
          raw_trace_run_ref: null,
          trace_id: 'trace-active',
          absolute_turn: 41,
          turn_ref: 'trace-active#41',
          ts: 1_781_587_500,
          runtime_profile: 'local',
          blocks: [{ block: 'keeper_instructions', bytes: 1200, digest: '1111222233334444' }],
          input_components: [],
          request_runtime_profile: null,
          request_body_bytes: null,
          execution_ids: [],
        },
        diff_vs_prev: null,
      },
      {
        record: {
          keeper: 'albini',
          agent_name: 'keeper-albini-agent',
          generation: 1,
          turn_kind: 'autonomous',
          raw_trace_run_ref: null,
          trace_id: 'trace-active',
          absolute_turn: 42,
          turn_ref: 'trace-active#42',
          ts: 1_781_587_560,
          runtime_profile: 'local',
          selected_model: 'deepseek-v4-flash',
          finish_reason: 'completed',
          input_tokens: 2400,
          output_tokens: 280,
          context_window: 203000,
          price_input_per_million: 0.27,
          price_output_per_million: 1.1,
          request_latency_ms: 1234,
          ttfrc_ms: 567.8,
          blocks: [
            { block: 'keeper_instructions', bytes: 1200, digest: '1111222233334444' },
            { block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' },
          ],
          input_components: [
            { component: 'prompt.keeper_instructions', bytes: 1200 },
            { component: 'prompt.memory_os_recall', bytes: 3392 },
          ],
          request_runtime_profile: 'local',
          request_body_bytes: 560_513,
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
  it('surfaces Memory OS recall blocks and the current snapshot revision', async () => {
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
    expect(text).toContain('revision 7')
    expect(text).toContain('facts 1/1')
    expect(text).toContain('+0 / −0')
    expect(text).toContain('retained 1')
    expect(text).toContain('latest revision memory change 없음')
    expect(text).toContain('store: .masc/config/keepers/albini.memory-current.json')
    expect(text).toContain('source: librarian · trace-active')
  })

  it('shows the current fresh-state snapshot without a retired fallback', async () => {
    const response = turnRecordsWithMemoryOs()
    response.memory_os.revision = 0
    response.memory_os.updated_at = null
    response.memory_os.update_source = null
    response.memory_os.facts = { shown: 0, current: 0, items: [] }
    response.memory_os.change = { added: [], removed: [], retained: 0, invalidated: [] }
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperMemoryOsRecallPanel} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('revision 0')
    })
    expect(container.textContent).toContain('facts 0/0')
  })

  it('shows derived basis and exact support invalidation premises', async () => {
    const response = turnRecordsWithMemoryOs()
    const memoryId = (digit: string) => `sha256:${digit.repeat(64)}`
    const premise = {
      memory_id: memoryId('a'),
      claim: 'observed premise',
      category: { tag: 'fact' as const },
      first_seen: 1_781_587_500,
      current: true,
      basis: { kind: 'observed' as const },
    }
    const conclusion = {
      memory_id: memoryId('b'),
      claim: 'derived conclusion',
      category: { tag: 'fact' as const },
      first_seen: 1_781_587_510,
      current: true,
      basis: {
        kind: 'derived' as const,
        derivations: [{ rule_id: 'supported_rule', premise_ids: [premise.memory_id] }],
      },
    }
    const missing = memoryId('d')
    const invalidated = {
      memory_id: memoryId('c'),
      claim: 'unsupported conclusion',
      category: { tag: 'fact' as const },
      first_seen: 1_781_587_400,
      current: false,
      basis: {
        kind: 'derived' as const,
        derivations: [{ rule_id: 'missing_rule', premise_ids: [missing] }],
      },
    }
    Object.assign(response.memory_os, {
      facts: { shown: 2, current: 2, items: [premise, conclusion] },
      change: {
        added: [conclusion],
        removed: [invalidated],
        retained: 1,
        invalidated: [{ fact: invalidated, missing_premise_ids: [missing] }],
      },
    })
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperMemoryOsRecallPanel} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('derived · 1 proof(s)')
    })
    expect(container.textContent).toContain('support invalidated 1')
    expect(container.textContent).toContain(missing)
  })
})

describe('KeeperTurnInspector v2 drawer', () => {
  beforeEach(() => {
    fetchKeeperToolCallsMock.mockResolvedValue(toolCallsForTurn())
    fetchKeeperProviderInputMock.mockResolvedValue(providerInputForTurn())
    Object.defineProperty(navigator, 'clipboard', {
      value: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
      writable: true,
      configurable: true,
    })
  })

  it('distinguishes incompatible retained rows from an empty turn history', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue({
      ...turnRecordsWithMemoryOs(),
      health: 'incompatible',
      stale_reason: 'incompatible_rows',
      skipped_rows: 3,
      count: 0,
      entries: [],
      latest_ts_unix: null,
      latest_ts_iso: null,
      latest_age_s: null,
    })

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('current decoder가 최근 3행을 모두 거부했습니다')
    })
    expect(container.textContent).not.toContain('턴 레코드 없음')
  })

  it('renders the detail drawer when a turn row is clicked', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    const summary = container.querySelector('.ti-turn-summary')
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

  it('renders input components sorted by bytes with the wire body size', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    const section = container.querySelector('[data-testid="turn-input-components"]')
    expect(section).toBeTruthy()
    const text = section?.textContent ?? ''
    expect(text).toContain('입력 구성')
    expect(text).toContain('prompt.memory_os_recall')
    expect(text).toContain('3.3KB')
    // Sorted by bytes descending: recall (3392B) precedes Keeper instructions (1200B).
    expect(text.indexOf('prompt.memory_os_recall')).toBeLessThan(text.indexOf('prompt.keeper_instructions'))
    expect(text).toContain('합계 4.5KB')
    expect(text).toContain('wire 547.4KB')
  })

  // The share is the answer to "can this keeper still see what it did 10 turns
  // ago". It is carried by its own observation, so it has to survive a turn
  // whose input-component attribution was unavailable — the shape
  // keeper_agent_run logs as "turn input composition unavailable".
  it('shows how much history a turn transmitted even without input components', async () => {
    const records = turnRecordsWithMemoryOs()
    const latestRow = records.entries.at(-1)
    if (!latestRow) throw new Error('fixture must carry a latest turn')
    const latest = latestRow.record
    latest.input_components = null
    latest.transmitted_atoms = 800
    latest.total_atoms = 5000
    fetchKeeperTurnRecordsMock.mockResolvedValue(records)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.querySelector('[data-testid="turn-input-components"]')).toBeNull()
    const atoms = container.querySelector('[data-testid="turn-transmitted-atoms"]')
    expect(atoms).toBeTruthy()
    const text = atoms?.textContent ?? ''
    expect(text).toContain('800')
    expect(text).toContain('5,000')
    expect(text).toContain('16.0%')
  })

  // A narrower window with no reason attached reads as an ordinary bad turn.
  // The decline does not age out, so a keeper can sit in it indefinitely —
  // which is why the basis is recorded rather than only logged.
  it('says when a turn was measured against the checkpoint instead of the wire', async () => {
    const records = turnRecordsWithMemoryOs()
    const latestRow = records.entries.at(-1)
    if (!latestRow) throw new Error('fixture must carry a latest turn')
    latestRow.record.transmitted_atoms = 12
    latestRow.record.total_atoms = 7000
    latestRow.record.model_input_measurement = 'durable_shape'
    fetchKeeperTurnRecordsMock.mockResolvedValue(records)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.querySelector('[data-testid="turn-measurement-declined"]')).toBeTruthy()
  })

  it('says nothing extra when the wire shape was measured', async () => {
    const records = turnRecordsWithMemoryOs()
    const latestRow = records.entries.at(-1)
    if (!latestRow) throw new Error('fixture must carry a latest turn')
    latestRow.record.transmitted_atoms = 12
    latestRow.record.total_atoms = 7000
    latestRow.record.model_input_measurement = 'wire_shape'
    fetchKeeperTurnRecordsMock.mockResolvedValue(records)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.querySelector('[data-testid="turn-transmitted-atoms"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="turn-measurement-declined"]')).toBeNull()
  })

  // Absence has to read as absence: a turn on a runtime that assembles its own
  // input carries no observation, and rendering 0 would say the keeper saw
  // nothing.
  it('renders nothing when the turn recorded no window observation', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.querySelector('[data-testid="turn-transmitted-atoms"]')).toBeNull()
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
        expect(container.querySelectorAll('.ti-turn-summary').length).toBe(3)
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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-messages"]')).toBeTruthy()
    })

    expect(container.querySelector('[data-testid="turn-tab-timeline"]')?.classList.contains('on')).toBe(true)
    expect(container.textContent).toContain('턴 워터폴')

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-messages"]')?.classList.contains('on')).toBe(true)
    })

    expect(container.textContent).toContain('실제 전송 메시지')

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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-tab-timeline"]')).toBeTruthy()
    })

    // The pill rail container is the tablist styled by .ti-tabs.
    const rail = container.querySelector('.ti-tabs')
    expect(rail).toBeTruthy()
    expect(rail?.getAttribute('role')).toBe('tablist')

    // Every tab is a .ti-tab pill (the class the CSS pill rule targets),
    // and the rail holds more than one pill so the gap/flex layout applies.
    const pills = rail!.querySelectorAll('.ti-tab')
    expect(pills.length).toBeGreaterThan(1)
    pills.forEach((pill) => {
      expect(pill.classList.contains('ti-tab')).toBe(true)
      expect(pill.getAttribute('role')).toBe('tab')
    })

    // Exactly one pill carries the active `.ti-tab.on` class (the volt-wash
    // fill state), and it is the timeline tab by default.
    const activePills = rail!.querySelectorAll('.ti-tab.on')
    expect(activePills.length).toBe(1)
    expect(activePills[0]?.getAttribute('data-testid')).toBe('turn-tab-timeline')
    expect(activePills[0]?.getAttribute('aria-selected')).toBe('true')

    // Switching tabs moves the single active pill, never duplicates it.
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      const nextActive = rail!.querySelectorAll('.ti-tab.on')
      expect(nextActive.length).toBe(1)
      expect(nextActive[0]?.getAttribute('data-testid')).toBe('turn-tab-meta')
    })
    expect(
      container.querySelector('[data-testid="turn-tab-timeline"]')?.classList.contains('on'),
    ).toBe(false)
  })

  it('grounds selected_model / finish_reason from the record and marks deferred fields n/a', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })

    const meta = container.querySelector('.ti-kv')?.textContent ?? ''
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
        selected_model: undefined,
        finish_reason: undefined,
      },
    }
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })

    const meta = container.querySelector('.ti-kv')?.textContent ?? ''
    expect(meta).not.toContain('stop')
    expect(meta).not.toContain('deepseek-v4-flash')
    expect(meta).toContain('n/a')
    // no raw trace run ref on this row — honest absence, never a fabricated one
    expect(meta).toContain('raw tracen/a')
  })

  it('renders the raw trace run ref in the meta tab when the record carries one', async () => {
    const response = turnRecordsWithMemoryOs()
    response.entries[1] = {
      ...response.entries[1]!,
      record: {
        ...response.entries[1]!.record,
        raw_trace_run_ref: {
          worker_run_id: 'wr-01H',
          path: '.masc/keepers/albini/raw-trace/wr-01H.jsonl',
          start_seq: 3,
          end_seq: 9,
          agent_name: 'keeper-albini-agent',
          session_id: 'trace-active',
        },
      },
    }
    fetchKeeperTurnRecordsMock.mockResolvedValue(response)

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

    await waitFor(() => {
      expect(container.textContent).toContain('실행 메타데이터')
    })

    const meta = container.querySelector('.ti-kv')?.textContent ?? ''
    expect(meta).toContain('raw tracewr-01H · seq 3-9')
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

      fireEvent.click(container.querySelector('.ti-turn-summary')!)
      fireEvent.click(container.querySelector('[data-testid="turn-tab-meta"]')!)

      await waitFor(() => {
        expect(container.textContent).toContain('샘플링 파라미터')
      })

      const params = Array.from(container.querySelectorAll('.ti-param')).map(el => el.textContent ?? '')
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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

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
    expect(drawerText).toContain('masc_board_post_get')
    // RFC-0233 §9/§10: the gen (response-generation) phase carries
    // request_latency_ms from the record (1234ms → "1.2s") plus ttfrc_ms
    // (567.8ms → "568ms"), so it renders a measured duration with the
    // time-to-first-token instead of "측정 없음".
    expect(drawerText).toContain('1.2s')
    expect(drawerText).toContain('첫 568ms')
    expect(drawerText).toContain('54ms')
    expect(drawerText).not.toContain('0.50s')

  })

  it('keeps joined tool calls with missing duration unmeasured, not 0ms', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperToolCallsMock.mockResolvedValue(toolCallsForTurnWithoutDuration())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    const drawerText = container.querySelector('[data-testid="turn-detail-drawer"]')?.textContent ?? ''
    expect(drawerText).toContain('masc_board_post_get')
    expect(drawerText).toContain('측정 없음')
    expect(drawerText).not.toContain('0ms')
    expect(drawerText).not.toContain('0.50s')

  })

  it('loads and renders the exact provider messages for the selected turn_ref', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-provider-messages"]')).toBeTruthy()
    })

    expect(fetchKeeperProviderInputMock).toHaveBeenCalledWith(
      'albini',
      'trace-active#42',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    const text = container.textContent ?? ''
    expect(text).toContain('실제 전송 메시지')
    expect(text).toContain('trace-active#42')
    expect(text).toContain('deploy the staging build')
    expect(text).toContain('previous keeper reply')
    expect(text).toContain('large tool result retained in this turn')
    expect(text).toContain('560,513B')
    expect(text).toContain('a'.repeat(64))
    expect(text).not.toContain('요청 · input')
    expect(text).not.toContain('응답 · result')
  })

  it('renders the exact system prompt and tool schemas in the context tab', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-context"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-provider-system-prompt"]')).toBeTruthy()
    })
    const text = container.textContent ?? ''
    expect(text).toContain('exact system prompt T42')
    expect(text).toContain('실제 도구 스키마')
    expect(text).toContain('masc_board_post_get')
    expect(text).toContain('read a board post')
    expect(text).not.toContain('당신은 MASC 코디네이션 서버의 keeper')
    expect(text).not.toContain('주입 컨텍스트')
  })

  it('rejects a provider-input response for a different turn', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperProviderInputMock.mockResolvedValue({
      ...providerInputForTurn(),
      absoluteTurn: 41,
      turnRef: 'trace-active#41',
    })

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-provider-input-error"]')).toBeTruthy()
    })
    expect(container.textContent).toContain('provider-input이 선택한 keeper 턴과 일치하지 않습니다')
    expect(container.textContent).not.toContain('deploy the staging build')
  })

  it('renders explicit absence when the provider-input snapshot cannot be loaded', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperProviderInputMock.mockRejectedValue(new Error('snapshot not found'))

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    fireEvent.click(container.querySelector('.ti-turn-summary')!)
    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.click(container.querySelector('[data-testid="turn-tab-messages"]')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-provider-input-error"]')).toBeTruthy()
    })
    expect(container.textContent).toContain('snapshot not found')
  })

  it('warns when the timing source fails while keeping turn records visible', async () => {
    fetchKeeperTurnRecordsMock.mockResolvedValue(turnRecordsWithMemoryOs())
    fetchKeeperToolCallsMock.mockRejectedValue(new Error('tool log unavailable'))

    const { container } = render(html`<${KeeperTurnInspector} keeperName="albini" />`)

    await waitFor(() => {
      expect(container.textContent).toContain('T42')
    })

    expect(container.textContent).toContain('tool-call timing source unavailable')

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('.ti-copy')).toBeTruthy()
    })

    const copyButtons = container.querySelectorAll('.ti-copy')
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

    fireEvent.click(container.querySelector('.ti-turn-summary')!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeTruthy()
    })

    fireEvent.keyDown(window, { key: 'Escape' })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="turn-detail-drawer"]')).toBeFalsy()
    })
  })
})
