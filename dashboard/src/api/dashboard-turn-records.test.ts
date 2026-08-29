import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())
const ensureDevToken = vi.hoisted(() => vi.fn(async () => undefined))

vi.mock('./core', () => ({
  get: getMock,
}))
vi.mock('./dev-token', () => ({ ensureDevToken }))

import { TURN_PROMPT_BLOCK_IDS, fetchKeeperTurnRecords } from './dashboard-turn-records'

function entry(overrides: Record<string, unknown> = {}) {
  return {
    record: {
      keeper: 'sangsu',
      // lib/types/turn_record.ml:148-163 writes these four on every row. The
      // fixture carried none of them until #26792, so the suite stayed green
      // against a shape the server had stopped sending.
      agent_name: 'keeper-sangsu-agent',
      generation: 1,
      turn_kind: 'autonomous',
      raw_trace_run_ref: null,
      trace_id: 'trace-1',
      absolute_turn: 7,
      turn_ref: 'trace-1#7',
      runtime_profile: 'anthropic.claude',
      ts: 1_700_000_000,
      execution_ids: ['exec-1'],
      blocks: [],
      input_components: [],
      request_runtime_profile: null,
      request_body_bytes: null,
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
    live_turn_in_progress: false,
    live_turn_started_at_unix: null,
    live_turn_last_progress_at_unix: null,
    latest_ts_unix: 1_700_000_000,
    latest_ts_iso: '2023-11-14T22:13:20Z',
    latest_age_s: 10,
    health: 'ok',
    stale_reason: null,
    memory_os: {
      keeper: 'sangsu',
      snapshot_store: '.masc/keepers/sangsu.memory-current.json',
      recall_enabled: true,
      revision: 0,
      updated_at: null,
      update_source: null,
      read_errors: [],
      facts: { shown: 0, current: 0, items: [] },
      change: { added: [], removed: [], retained: 0 },
    },
    entries,
  }
}

afterEach(() => {
  getMock.mockReset()
})

// #25779 made the provider cache token counts durable on the turn record, but
// the decoder rebuilt each entry without them, so they were discarded before
// reaching the inspector. Absent stays absent — a provider that reports no
// cache count must not decode to a fabricated 0.
describe('keeper turn record cache token counts', () => {
  it('surfaces a current-only window containing only incompatible rows', async () => {
    getMock.mockResolvedValue({
      ...payload(),
      skipped_rows: 12,
      latest_ts_unix: null,
      latest_ts_iso: null,
      latest_age_s: null,
      health: 'incompatible',
      stale_reason: 'incompatible_rows',
    })

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response).toMatchObject({
      count: 0,
      skipped_rows: 12,
      health: 'incompatible',
      stale_reason: 'incompatible_rows',
      entries: [],
    })
  })

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

    getMock.mockResolvedValue(payload(entry({ selected_model: ' ' })))
    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('projects the record identity fields the writer always emits', async () => {
    getMock.mockResolvedValue(payload(entry()))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record).toMatchObject({
      agent_name: 'keeper-sangsu-agent',
      generation: 1,
      turn_kind: 'autonomous',
      raw_trace_run_ref: null,
    })
  })

  it('projects a populated exact-run reference', async () => {
    const run_ref = {
      worker_run_id: 'wr-1',
      path: '/keepers/sangsu/raw-traces/turn-1.jsonl',
      start_seq: 1,
      end_seq: 4,
      agent_name: 'agent-core-ollama_cloud.deepseek-v4-flash',
      session_id: 'trace-1',
    }
    getMock.mockResolvedValue(payload(entry({ raw_trace_run_ref: run_ref })))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record.raw_trace_run_ref).toEqual(run_ref)
  })

  it.each([
    ['agent_name', { agent_name: '' }],
    ['generation', { generation: -1 }],
    ['turn_kind', { turn_kind: 'scheduled' }],
    ['raw_trace_run_ref', { raw_trace_run_ref: { worker_run_id: 'wr-1' } }],
  ])('rejects a row whose %s violates the writer contract', async (_field, override) => {
    getMock.mockResolvedValue(payload(entry(override)))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a row that omits a field the writer always emits', async () => {
    const row = entry()
    delete (row.record as Record<string, unknown>).turn_kind
    getMock.mockResolvedValue(payload(row))

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

  it('rejects the retired unversioned model field', async () => {
    getMock.mockResolvedValue(payload(entry({ model: 'runtime' })))

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

  it('rejects the retired Memory OS schema field', async () => {
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

describe('keeper turn record live-turn envelope', () => {
  // #28216 made the server emit live_turn_in_progress / started_at /
  // last_progress_at unconditionally. Until the decoder recognised the
  // three fields its exact-envelope check rejected the whole response, so
  // every turn-records load failed with an invalid-payload error.
  it('decodes a response whose live turn is in progress', async () => {
    const raw = payload(entry())
    Object.assign(raw, {
      live_turn_in_progress: true,
      live_turn_started_at_unix: 1_700_000_020,
      live_turn_last_progress_at_unix: 1_700_000_028,
    })
    getMock.mockResolvedValue(raw)

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response).toMatchObject({
      live_turn_in_progress: true,
      live_turn_started_at_unix: 1_700_000_020,
      live_turn_last_progress_at_unix: 1_700_000_028,
    })
  })

  it('keeps the idle envelope (false with both timestamps null)', async () => {
    getMock.mockResolvedValue(payload(entry()))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response).toMatchObject({
      live_turn_in_progress: false,
      live_turn_started_at_unix: null,
      live_turn_last_progress_at_unix: null,
    })
  })

  it('rejects a missing live_turn_in_progress field', async () => {
    const raw = payload(entry())
    delete (raw as Record<string, unknown>).live_turn_in_progress
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects a live turn whose timestamps disagree with in_progress', async () => {
    const raw = payload(entry())
    Object.assign(raw, {
      live_turn_in_progress: true,
      live_turn_started_at_unix: null,
      live_turn_last_progress_at_unix: null,
    })
    getMock.mockResolvedValue(raw)

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })
})

describe('keeper turn record final input composition', () => {
  it('carries exact serialized request body bytes with the observing runtime', async () => {
    getMock.mockResolvedValue(payload(entry({
      request_runtime_profile: 'anthropic.fallback',
      request_body_bytes: 560_513,
    })))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record).toMatchObject({
      request_runtime_profile: 'anthropic.fallback',
      request_body_bytes: 560_513,
    })
  })

  it('rejects rows without the current request-wire observation contract', async () => {
    getMock.mockResolvedValue(payload(entry({ request_body_bytes: undefined })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it.each([
    { request_runtime_profile: 'anthropic.fallback', request_body_bytes: null },
    { request_runtime_profile: null, request_body_bytes: 560_513 },
    { request_runtime_profile: 'anthropic.fallback', request_body_bytes: -1 },
  ])('rejects a partial or invalid request-wire pair', async (observation) => {
    getMock.mockResolvedValue(payload(entry(observation)))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('carries typed content components through the decoder', async () => {
    getMock.mockResolvedValue(payload(entry({
      input_components: [
        { component: 'prompt.keeper_instructions', bytes: 1200 },
        { component: 'tool_schemas', bytes: 64000 },
        { component: 'message_tool_result', bytes: 2800 },
      ],
    })))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record.input_components).toEqual([
      { component: 'prompt.keeper_instructions', bytes: 1200 },
      { component: 'tool_schemas', bytes: 64000 },
      { component: 'message_tool_result', bytes: 2800 },
    ])
  })

  // The decoder switch and TURN_PROMPT_BLOCK_IDS are two copies of the same
  // list, and they drifted: 'operator_note' shipped in the constant and in the
  // OCaml producer (prompt_block_id.ml:24) but never reached the switch, so a
  // turn carrying an operator note failed decodeTurnInputComponents and was
  // rejected whole. Walk the constant so the next block added cannot repeat it.
  it.each([...TURN_PROMPT_BLOCK_IDS])('decodes the %s prompt component', async (block) => {
    getMock.mockResolvedValue(payload(entry({
      input_components: [{ component: `prompt.${block}`, bytes: 1 }],
    })))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record.input_components).toEqual([
      { component: `prompt.${block}`, bytes: 1 },
    ])
  })

  it('preserves explicit unavailable composition instead of inventing an empty list', async () => {
    getMock.mockResolvedValue(payload(entry({
      input_components: null,
      request_runtime_profile: 'anthropic.fallback',
      request_body_bytes: 560_513,
    })))

    const response = await fetchKeeperTurnRecords('sangsu')

    expect(response.entries[0]?.record.input_components).toBeNull()
  })

  it('rejects rows without the current composition contract', async () => {
    getMock.mockResolvedValue(payload(entry({ input_components: undefined })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects unknown component ids instead of inventing a bucket', async () => {
    getMock.mockResolvedValue(payload(entry({
      input_components: [{ component: 'history_guess', bytes: 1 }],
    })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects prompt blocks without a current producer', async () => {
    getMock.mockResolvedValue(payload(entry({
      blocks: [{ block: 'continuity', bytes: 1, digest: 'dead-block' }],
    })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects prompt components without a current producer', async () => {
    getMock.mockResolvedValue(payload(entry({
      input_components: [{ component: 'prompt.retry_nudge', bytes: 1 }],
    })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('rejects duplicate component ids', async () => {
    const component = { component: 'tool_schemas', bytes: 1 }
    getMock.mockResolvedValue(payload(entry({
      input_components: [component, component],
    })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })

  it('accepts only current unique blocks with lowercase sha256 digests', async () => {
    getMock.mockResolvedValue(payload(entry({
      blocks: [{
        block: 'keeper_instructions',
        bytes: 4,
        digest: 'a'.repeat(64),
      }],
    })))

    const response = await fetchKeeperTurnRecords('sangsu')
    expect(response.entries[0]?.record.blocks).toEqual([{
      block: 'keeper_instructions',
      bytes: 4,
      digest: 'a'.repeat(64),
    }])
  })

  it.each([
    { blocks: [{ block: 'keeper_instructions', bytes: 4, digest: 'A'.repeat(64) }] },
    {
      blocks: [
        { block: 'keeper_instructions', bytes: 4, digest: 'a'.repeat(64) },
        { block: 'keeper_instructions', bytes: 5, digest: 'b'.repeat(64) },
      ],
    },
  ])('rejects malformed or duplicate current blocks', async ({ blocks }) => {
    getMock.mockResolvedValue(payload(entry({ blocks })))

    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow(
      '유효하지 않은 keeper turn record payload',
    )
  })
})

describe('turn-records health: live vs ok (masc#28720)', () => {
  it('accepts a live keeper whose newest finished record is past the SLO', async () => {
    // The live case that used to be reported as 'ok'. taskmaster on 2026-08-14:
    // latest_age_s 539.99 against a 420s SLO with a turn running. The decoder
    // recomputed the age, called the response a contract violation, and the
    // memory inspector rendered "유효하지 않은 keeper turn record payload".
    getMock.mockResolvedValue({
      ...payload(entry()),
      freshness_slo_s: 420,
      latest_age_s: 540,
      live_turn_in_progress: true,
      live_turn_started_at_unix: 1_700_000_100,
      live_turn_last_progress_at_unix: 1_700_000_200,
      health: 'live',
    })
    const response = await fetchKeeperTurnRecords('sangsu')
    expect(response.health).toBe('live')
    expect(response.entries.length).toBe(1)
  })

  it("accepts a keeper's first turn: live with no records yet", async () => {
    getMock.mockResolvedValue({
      ...payload(),
      latest_ts_unix: null,
      latest_ts_iso: null,
      latest_age_s: null,
      live_turn_in_progress: true,
      live_turn_started_at_unix: 1_700_000_100,
      live_turn_last_progress_at_unix: 1_700_000_200,
      health: 'live',
    })
    const response = await fetchKeeperTurnRecords('sangsu')
    expect(response.health).toBe('live')
    expect(response.entries.length).toBe(0)
  })

  it('rejects live without a turn actually running', async () => {
    getMock.mockResolvedValue({ ...payload(entry()), health: 'live' })
    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow()
  })

  it('still rejects ok when the newest record is past the SLO', async () => {
    getMock.mockResolvedValue({
      ...payload(entry()),
      freshness_slo_s: 420,
      latest_age_s: 540,
    })
    await expect(fetchKeeperTurnRecords('sangsu')).rejects.toThrow()
  })
})
