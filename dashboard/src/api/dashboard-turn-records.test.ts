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
      runtime_profile: 'anthropic.claude',
      ts: 1_700_000_000,
      execution_ids: ['exec-1'],
      blocks: [],
      input_tokens: 1200,
      output_tokens: 340,
      ...overrides,
    },
  }
}

function payload(...entries: ReturnType<typeof entry>[]) {
  return { keeper: 'sangsu', count: entries.length, skipped_rows: 0, entries }
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

  it('does not coerce a non-numeric count into a number', async () => {
    getMock.mockResolvedValue(
      payload(entry({ cache_read_input_tokens: 'many', cache_creation_input_tokens: null })),
    )

    const response = await fetchKeeperTurnRecords('sangsu')
    const record = response.entries[0]?.record

    expect(record?.cache_read_input_tokens).toBeUndefined()
    expect(record?.cache_creation_input_tokens).toBeUndefined()
  })
})
