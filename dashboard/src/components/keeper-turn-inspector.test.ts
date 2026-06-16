// @vitest-environment happy-dom
import { cleanup, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperTurnRecords, type TurnRecordsResponse } from '../api/dashboard'
import { KeeperMemoryOsRecallPanel } from './keeper-turn-inspector'

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
          blocks: [
            { block: 'system', bytes: 1200, digest: '1111222233334444' },
            { block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' },
          ],
          execution_ids: ['exec-42'],
        },
        diff_vs_prev: {
          added: [{ block: 'memory_os_recall', bytes: 3392, digest: 'aabbccddeeff00112233' }],
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
