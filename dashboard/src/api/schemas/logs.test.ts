import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import { decodeLogsData, LogsSchemaDriftError } from './logs'

function currentEntry(overrides: Record<string, unknown> = {}) {
  return {
    seq: 42,
    ts: '2026-04-17T00:00:00Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    keeper_name: 'system',
    turn_id: null,
    message: 'booted',
    details: null,
    category: null,
    ...overrides,
  }
}

function currentWire(entries: readonly Record<string, unknown>[] = []) {
  const newest = entries[0]
  const oldest = entries[entries.length - 1]
  return {
    generated_at_iso: '2026-05-15T01:00:00Z',
    dashboard_surface: '/api/v1/dashboard/logs',
    source: 'masc_log_ring',
    retention: {
      scope: 'dashboard_logs',
      workspace_root: '/Users/dancer/me/.masc',
      buffer: 'Log.Ring',
      capacity: 50000,
      durable_store: '/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl',
      file_pattern: 'system_log_YYYY-MM-DD.jsonl',
      keep_days: 7,
      cache_policy: 'uncached',
    },
    query: {
      limit: 200,
      level: 'INFO',
      applied_level: 'INFO',
      min_level: 1,
      module: '',
      since_seq: null,
      before_seq: null,
      category: null,
      exclude_category: null,
    },
    returned: entries.length,
    latest_seq: typeof newest?.seq === 'number' ? newest.seq : null,
    oldest_seq: typeof oldest?.seq === 'number' ? oldest.seq : null,
    latest_ts_iso: typeof newest?.ts === 'string' ? newest.ts : null,
    total: entries.length,
    entries,
  }
}

function expectDrift(value: unknown): LogsSchemaDriftError {
  const error = Effect.runSync(Effect.flip(decodeLogsData(value)))
  expect(error).toBeInstanceOf(LogsSchemaDriftError)
  expect(error.message).toContain('logs schema drift')
  return error
}

describe('decodeLogsData', () => {
  it('strictly decodes the empty current response', () => {
    const data = Effect.runSync(decodeLogsData(currentWire()))

    expect(data.total).toBe(0)
    expect(data.entries).toEqual([])
    expect(data.retention.scope).toBe('dashboard_logs')
  })

  it('maps wire absence to product values once', () => {
    const data = Effect.runSync(
      decodeLogsData(currentWire([currentEntry()])),
    )

    expect(data.entries[0]).toEqual({
      seq: 42,
      timestamp: '2026-04-17T00:00:00Z',
      level: 'INFO',
      source: 'structured',
      module: 'Keeper',
      keeperName: 'system',
      hasTurn: false,
      message: 'booted',
      details: {},
      category: 'uncategorized',
      hasExplicitCategory: false,
    })
  })

  it('keeps current closed variants and structured details', () => {
    const data = Effect.runSync(decodeLogsData(currentWire([
      currentEntry({
        keeper_name: 'reviewer',
        turn_id: 7,
        category: 'tool',
        details: { tool_name: 'masc_status' },
      }),
    ])))
    const entry = data.entries[0]

    expect(entry?.keeperName).toBe('reviewer')
    expect(entry?.hasTurn).toBe(true)
    expect(entry?.category).toBe('tool')
    expect(entry?.hasExplicitCategory).toBe(true)
    expect(entry?.details).toEqual({ tool_name: 'masc_status' })
  })

  it.each([
    ['non-array entries', { ...currentWire(), entries: null }],
    ['missing required envelope field', (() => {
      const wire = currentWire()
      const { retention: _retention, ...rest } = wire
      return rest
    })()],
    ['row missing a required field', currentWire([{ seq: 1, ts: 'now' }])],
    ['unknown level', currentWire([currentEntry({ level: 'TRACE' })])],
    ['unknown source', currentWire([currentEntry({ source: 'sse' })])],
    ['unknown category', currentWire([currentEntry({ category: 'provider' })])],
    ['excess property', { ...currentWire(), dropped_entries: 1 }],
  ])('rejects %s', (_name, value) => {
    expectDrift(value)
  })

  it('rejects envelope counts that disagree with entries', () => {
    const error = expectDrift({
      ...currentWire([currentEntry()]),
      returned: 0,
    })
    expect(error.message).toContain('returned')
  })

  it('rejects entries that are not newest-seq-first', () => {
    const entries = [currentEntry({ seq: 41 }), currentEntry({ seq: 42 })]
    const wire = currentWire(entries)
    const error = expectDrift({
      ...wire,
      latest_seq: 41,
      oldest_seq: 42,
      latest_ts_iso: entries[0]?.ts,
    })
    expect(error.message).toContain('newest-seq-first')
  })
})
