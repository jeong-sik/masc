import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchKeeperTurnRecords } from './dashboard-turn-records'

function entry(overrides: Record<string, unknown> = {}) {
  return {
    record: {
      keeper: 'sangsu',
      trace_id: 'trace-1',
      absolute_turn: 7,
      turn_ref: 'trace-1#7',
      runtime_profile: 'anthropic.claude',
      ts: 1_700_000_000,
      execution_ids: ['exec-1'],
      blocks: [],
      input_tokens: 1200,
      output_tokens: 340,
      ...overrides,
    },
    diff_vs_prev: null,
  }
}

function payload(...entries: ReturnType<typeof entry>[]) {
  return {
    keeper: 'sangsu',
    count: entries.length,
    skipped_rows: 0,
    source: 'turn_record',
    producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
    durable_store: '.masc/keepers/sangsu/turn-records',
    dashboard_surface: '/api/v1/keepers/:name/turn-records',
    freshness_slo_s: 300,
    latest_ts_unix: 1_700_000_000,
    latest_ts_iso: '2023-11-14T22:13:20Z',
    latest_age_s: 10,
    health: 'ok',
    stale_reason: null,
    memory_os: {
      schema: 'keeper.memory_os.recall_observability.v2',
      keeper: 'sangsu',
      source: 'memory_os_files',
      producer: 'keeper_librarian|keeper_memory_os_recall',
      selection_policy: {
        keeper_scope: 'sangsu',
        facts_source: 'Keeper_memory_os_io.read_facts_all_for_keepers_dir',
        episodes_source: 'Keeper_memory_os_io.read_episodes_all_for_keepers_dir',
        category_source: 'Keeper_memory_os_types.category_to_string',
        recall_block: 'Keeper_memory_os_recall.render_if_enabled',
        prompt_record: 'Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall',
      },
      facts_store: '.masc/config/keepers/sangsu.facts.jsonl',
      episodes_store: '.masc/config/keepers/sangsu/episodes',
      recall_enabled: true,
      read_errors: [],
      episodes: { shown: 0, terminal_markers: 0, items: [] },
      facts: { shown: 0, items: [] },
    },
    entries,
  }
}

afterEach(() => {
  getMock.mockReset()
})

// #25779 made the provider cache token counts durable on the turn record, but
// the decoder rebuilt each entry without them, so they were discarded before
// reaching the inspector. Absent stays absent — a legacy row must not decode to
// a fabricated 0.
describe('keeper turn record cache token counts', () => {
  it('carries the durable cache counts through the decoder', async () => {
    getMock.mockResolvedValue(
      payload(entry({ cache_creation_input_tokens: 900, cache_read_input_tokens: 15_400 })),
    )

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries).toHaveLength(1)
    expect(response.entries[0]?.record).toMatchObject({
      turn_ref: 'trace-1#7',
      input_tokens: 1200,
      output_tokens: 340,
      cache_creation_input_tokens: 900,
      cache_read_input_tokens: 15_400,
    })
  })

  it('leaves the counts undefined when the row does not carry them', async () => {
    getMock.mockResolvedValue(payload(entry()))

    const response = await fetchKeeperTurnRecords('sangsu')
    const record = response.entries[0]?.record

    expect(record?.cache_creation_input_tokens).toBeUndefined()
    expect(record?.cache_read_input_tokens).toBeUndefined()
  })

  it('accepts a fractional producer timestamp with its exact whole-second ISO projection', async () => {
    const fractionalTs = 1_700_000_000.123456
    const raw = payload(entry({ ts: fractionalTs }))
    raw.latest_ts_unix = fractionalTs
    getMock.mockResolvedValue(raw)

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.latest_ts_unix).toBe(fractionalTs)
    expect(response.latest_ts_iso).toBe('2023-11-14T22:13:20Z')
  })

  it('rejects an ISO projection for a different whole second', async () => {
    const raw = payload(entry())
    raw.latest_ts_iso = '2023-11-14T22:13:21Z'
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a present optional field with the wrong current wire type', async () => {
    getMock.mockResolvedValue(
      payload(entry({ cache_read_input_tokens: 'many', cache_creation_input_tokens: null })),
    )

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a malformed turn row instead of silently dropping it', async () => {
    const malformed = entry({
      blocks: [{ block: 'memory_os_recall', bytes: -1, digest: 'digest' }],
    })
    getMock.mockResolvedValue(payload(malformed))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a response count that disagrees with the exact decoded rows', async () => {
    const raw = payload(entry())
    raw.count = 2
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects fields outside the exact current response envelope', async () => {
    const raw = { ...payload(entry()), legacy_cursor: 'retired' }
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects fields outside the exact current nested record', async () => {
    getMock.mockResolvedValue(payload(entry({ lease_id: 'retired' })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects removed Memory OS retention fields', async () => {
    const raw = payload(entry())
    Object.assign(raw.memory_os.facts, { current: 0, expired: 0 })
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects the retired Memory OS wire contract token', async () => {
    const raw = payload(entry())
    Object.assign(raw.memory_os, { schema: 'keeper.memory_os.recall_observability.v1' })
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a missing current turn_ref', async () => {
    getMock.mockResolvedValue(payload(entry({ turn_ref: undefined })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a turn_ref that disagrees with trace_id and absolute_turn', async () => {
    getMock.mockResolvedValue(payload(entry({ turn_ref: 'trace-1#8' })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })
})
