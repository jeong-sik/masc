// @vitest-environment happy-dom
import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { signal } from '@preact/signals'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

import type {
  ToolCallsResponse,
  TrajectoryResponse,
} from '../../api/dashboard'
import type { KeeperRuntimeTraceResponse } from '../../api/keeper'
import type { JournalEntry, Keeper } from '../../types'

function trajectory(): TrajectoryResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    generation: 1,
    total_entries: 2,
    showing: 2,
    entries: [
      {
        ts: 1,
        ts_iso: '2026-05-14T00:00:01.000Z',
        turn: 1,
        type: 'thinking',
        content_withheld: true,
        redacted: true,
        char_count: 42,
      },
      {
        ts: 2,
        ts_iso: '2026-05-14T00:00:02.000Z',
        turn: 1,
        round: 1,
        tool_name: 'fs_read',
        args: { path: '/tmp/old' },
        gate: { status: 'reject', reason: '쓰기 위험이 있어 운영자 승인 대기로 전환됨' },
        result: 'old result',
        duration_ms: 120,
      },
    ],
  }
}

function toolCalls(): ToolCallsResponse {
  return {
    keeper: 'keeper-a',
    count: 1,
    entries: [
      {
        ts: 2,
        keeper: 'keeper-a',
        tool: 'fs_read',
        input: { file_path: '/tmp/current' },
        output: 'current result',
        success: true,
        duration_ms: 120,
        trace_id: 'trace-1',
        turn: 1,
        planned_index: 4,
        batch_index: 0,
        batch_size: 2,
        execution_mode: 'concurrent',
      },
    ],
  }
}

function runtimeTrace(): KeeperRuntimeTraceResponse {
  return {
    keeper: 'keeper-a',
    trace_id: 'trace-1',
    turn_id: 1,
    manifest_path: '.masc/keepers/keeper-a/runtime.jsonl',
    manifest_path_present: true,
    manifest_total_rows: 5,
    manifest_returned_rows: 5,
    receipt_returned_rows: 1,
    manifest_scan_diagnostics: {
      state: 'available',
      schema: 'keeper.runtime_manifest_scan_diagnostics.v1',
      unsupported_event_count: 0,
      unsupported_event_counts: [],
      unsupported_event_unattributed_count: 0,
      invalid_manifest_row_count: 0,
      invalid_json_row_count: 0,
      samples: [],
    },
    turn_identity: {
      requested_keeper_turn_id: 1,
      manifest_keeper_turn_ids: [1],
      receipt_turn_counts: [2],
      max_agent_core_turn_count: 2,
      provider_lane_resolved_count: 1,
      runtime_completed_count: 1,
      runtime_failed_count: 0,
      checkpoint_saved_count: 1,
      event_bus_correlated_count: 1,
      memory_injected_count: 1,
      memory_flushed_count: 1,
      receipt_appended_count: 1,
      turn_finished_count: 1,
    },
    event_bus: {
      event_bus_correlated_count: 1,
      correlation_ids: ['corr-1'],
      run_ids: ['run-1'],
    },
    memory: {
      memory_injected_count: 1,
      memory_injected_present_count: 1,
      memory_flushed_count: 1,
      memory_flush_success_count: 1,
      memory_flush_error_count: 0,
      episodes_flushed: 0,
      procedures_flushed: 0,
    },
    runtime_lens: {
      turn_clock: {
        trace_id: 'trace-1',
        keeper_turn_id: 1,
        max_agent_core_turn_count: 2,
        terminal_event_present: true,
        terminal_event: 'turn_finished',
        manifest_total_rows: 5,
      },
      axes: {} as KeeperRuntimeTraceResponse['runtime_lens']['axes'],
      swimlanes: {} as KeeperRuntimeTraceResponse['runtime_lens']['swimlanes'],
      clock_edges: [],
      clock_groups: [],
      gaps: [],
    },
    linked_artifacts: {
      receipts: [],
      checkpoints: [],
      tool_call_logs: [],
    },
    manifest_rows: [],
    receipts: [],
    health: 'ok',
    stale_reason: null,
  }
}

function keeperRow(name: string, extra: Partial<Keeper> = {}): Keeper {
  return {
    name,
    status: 'active',
    keepalive_running: true,
    turn_count: 7,
    ...extra,
  } as Keeper
}

function journalEntry(overrides: Partial<JournalEntry>): JournalEntry {
  return {
    agent: 'keeper-a',
    text: 'entry text',
    timestamp: Date.now(),
    ...overrides,
  }
}

async function loadPanel({
  keeperRows = [keeperRow('keeper-a')],
  journalEntries = [] as JournalEntry[],
} = {}) {
  vi.resetModules()
  const keeperSignal = signal<readonly Keeper[]>(keeperRows)
  const journalSignal = signal<JournalEntry[]>(journalEntries)
  const fetchKeeperTrajectory = vi.fn().mockResolvedValue(trajectory())
  const fetchKeeperToolCalls = vi.fn().mockResolvedValue(toolCalls())
  const fetchKeeperRuntimeTrace = vi.fn().mockResolvedValue(runtimeTrace())

  vi.doMock('../../store', () => ({ keepers: keeperSignal }))
  vi.doMock('../../sse', () => ({ journal: journalSignal }))
  vi.doMock('../../api/dashboard', () => ({
    fetchKeeperTrajectory,
    fetchKeeperToolCalls,
  }))
  vi.doMock('../../api/keeper', () => ({
    fetchKeeperRuntimeTrace,
  }))

  const mod = await import('./journey-v2')
  return {
    JourneyV2Panel: mod.JourneyV2Panel,
    journalSignal,
    fetchKeeperTrajectory,
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.resetModules()
  vi.doUnmock('../../store')
  vi.doUnmock('../../sse')
  vi.doUnmock('../../api/dashboard')
  vi.doUnmock('../../api/keeper')
})

describe('JourneyV2Panel', () => {
  it('renders the prototype DOM vocabulary wired to the live waterfall sources', async () => {
    const { JourneyV2Panel, fetchKeeperTrajectory } = await loadPanel()

    const { container } = render(h(JourneyV2Panel, {}))

    await waitFor(() => {
      expect(screen.getByText('턴 워터폴')).toBeInTheDocument()
      expect(screen.getByText('1번째 턴')).toBeInTheDocument()
    })
    expect(fetchKeeperTrajectory).toHaveBeenCalledWith('keeper-a', 200, true, true)

    // prototype class hooks emitted by the panel chrome
    expect(container.querySelector('.ia-wrap.jw-wrap')).not.toBeNull()
    expect(container.querySelector('.ia-devslot')).not.toBeNull()
    expect(container.querySelectorAll('.lq-kpis .lq-kpi')).toHaveLength(5)
    expect(container.querySelector('.lq-tabs .lq-tab.on')).toHaveTextContent('keeper-a')

    // first turn card is open by default (design open='t0'): track + evidence
    expect(container.querySelector('.jw-turn.open')).not.toBeNull()
    expect(container.querySelector('.jw-track .jw-think .jw-think-m')).not.toBeNull()
    expect(container.querySelector('.jw-track .jw-lane .jw-bar')).not.toBeNull()
    expect(container.querySelector('.jw-scale')).not.toBeNull()
    expect(container.querySelector('.jw-ev .jw-ev-i')).not.toBeNull()

    // KPI values derive from the loaded waterfall summary
    expect(screen.getByText('생각 · 도구')).toBeInTheDocument()
  })

  it('opens the entry detail with status chip, gate reason and dev source on bar click', async () => {
    const { JourneyV2Panel } = await loadPanel()
    const { container } = render(h(JourneyV2Panel, {}))

    await waitFor(() => {
      expect(container.querySelector('.jw-bar')).not.toBeNull()
    })

    fireEvent.click(container.querySelector('.jw-bar') as Element)

    await waitFor(() => {
      expect(container.querySelector('.jw-detail[data-tone="warn"]')).not.toBeNull()
      expect(container.querySelector('.jw-detail .lq-chip')).toHaveTextContent('승인 대기로 전환')
      expect(screen.getByText('쓰기 위험이 있어 운영자 승인 대기로 전환됨')).toBeInTheDocument()
    })

    // dev toggle reveals the raw source chip (jw-src)
    expect(container.querySelector('.jw-src')).toBeNull()
    fireEvent.click(screen.getByText('기술 상세'))
    await waitFor(() => {
      expect(container.querySelector('.jw-src')).not.toBeNull()
    })
  })

  it('marks keepers without recorded turns with lq-tab-none and shows the empty treatment', async () => {
    const { JourneyV2Panel } = await loadPanel({
      keeperRows: [
        keeperRow('keeper-a'),
        keeperRow('keeper-b', { turn_count: undefined, total_turns: undefined, last_turn_ago_s: undefined }),
      ],
    })
    const { container } = render(h(JourneyV2Panel, {}))

    await waitFor(() => {
      expect(screen.getByText('1번째 턴')).toBeInTheDocument()
    })
    const tabs = [...container.querySelectorAll('.lq-tab')]
    const staleTab = tabs.find(tab => tab.textContent?.includes('keeper-b'))
    expect(staleTab?.querySelector('.lq-tab-none')).not.toBeNull()
  })

  it('shows the design empty treatment when no turn records exist', async () => {
    vi.resetModules()
    const keeperSignal = signal<readonly Keeper[]>([keeperRow('keeper-a')])
    vi.doMock('../../store', () => ({ keepers: keeperSignal }))
    vi.doMock('../../sse', () => ({ journal: signal<JournalEntry[]>([]) }))
    vi.doMock('../../api/dashboard', () => ({
      fetchKeeperTrajectory: vi.fn().mockResolvedValue({
        keeper: 'keeper-a', trace_id: 't', generation: 1, total_entries: 0, showing: 0, entries: [],
      }),
      fetchKeeperToolCalls: vi.fn().mockResolvedValue({ keeper: 'keeper-a', count: 0, entries: [] }),
    }))
    vi.doMock('../../api/keeper', () => ({
      fetchKeeperRuntimeTrace: vi.fn().mockResolvedValue(runtimeTrace()),
    }))
    const { JourneyV2Panel } = await import('./journey-v2')

    const { container } = render(h(JourneyV2Panel, {}))

    await waitFor(() => {
      expect(screen.getByText('최근 턴 기록 없음')).toBeInTheDocument()
    })
    expect(container.querySelector('.lq-gap')).not.toBeNull()
    // runtime trace loaded but no matching turn → evidence strip renders the
    // design's "no record" variant only when a turn exists; with zero turns
    // the whole waterfall is the empty treatment.
    expect(container.querySelector('.jw-turn')).toBeNull()
  })

  it('live strip filters journal entries and renders rate/count rows', async () => {
    const entries: JournalEntry[] = [
      journalEntry({ eventType: 'keeper_heartbeat', text: '큐에이킹 · 정상 동작' }),
      journalEntry({ eventType: 'board_post', text: 'sangsu · T-3880 에 의견 남김' }),
      journalEntry({ eventType: 'keeper_tool_call', text: '셸 명령이 승인 대기로 전환됨', severity: 'error' }),
    ]
    const { JourneyV2Panel } = await loadPanel({ journalEntries: entries })
    const { container } = render(h(JourneyV2Panel, {}))

    await waitFor(() => {
      expect(screen.getByText('라이브 이벤트')).toBeInTheDocument()
    })
    expect(container.querySelectorAll('.ev-rows .ev-row')).toHaveLength(3)
    expect(container.querySelector('.ev-rate')).toHaveTextContent('3/min')
    expect(container.querySelector('.ev-count')).toHaveTextContent('3 events')

    // error filter keeps only error-severity entries
    fireEvent.click(screen.getByText('오류'))
    await waitFor(() => {
      expect(container.querySelectorAll('.ev-rows .ev-row')).toHaveLength(1)
    })
    expect(container.querySelector('.ev-row .lq-chip')).toHaveTextContent('도구')
    expect(container.querySelector('.ev-row .ev-text')).toHaveTextContent('셸 명령이 승인 대기로 전환됨')
    expect(container.querySelector('.ev-row .ev-ago')).not.toBeNull()

    // lifecycle filter matches nothing → design's empty treatment
    fireEvent.click(screen.getByText('상태 변화'))
    await waitFor(() => {
      expect(screen.getByText('해당 이벤트 없음')).toBeInTheDocument()
    })
  })
})
