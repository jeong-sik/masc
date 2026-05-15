import { describe, expect, it } from 'vitest'

import {
  LogsSchemaDriftError,
  parseLogsResponse,
} from './logs'

// RFC-0079: backend writes a typed encoder (see lib/masc_log/log.ml
// Ring.entry_to_json). The legacy fallback fields raw_level /
// normalized_level / legacy_classified are gone with the string-prefix
// classifier that produced them. dropped_entries is gone too — silent
// per-entry skipping is now a strict schema-drift error.

function validEntry(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    seq: 42,
    ts: '2026-04-17T00:00:00Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    message: 'booted',
    keeper_name: null,
    turn_id: null,
    details: null,
    ...overrides,
  }
}

describe('parseLogsResponse', () => {
  it('accepts an empty response', () => {
    const out = parseLogsResponse({ total: 0, entries: [] })
    expect(out.total).toBe(0)
    expect(out.entries).toHaveLength(0)
  })

  it('parses a populated response', () => {
    const out = parseLogsResponse({
      total: 2,
      generated_at_iso: '2026-05-15T01:00:00Z',
      dashboard_surface: '/api/v1/dashboard/logs',
      source: 'masc_log_ring',
      retention: {
        scope: 'dashboard_logs',
        coordination_root: '/Users/dancer/me/.masc',
        buffer: 'Log.Ring',
        capacity: 50000,
        durable_store: '/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl',
        file_pattern: 'system_log_YYYY-MM-DD.jsonl',
        keep_days: 7,
      },
      query: {
        limit: 200,
        level: 'INFO',
        applied_level: 'INFO',
        min_level: 1,
        module: '',
        since_seq: null,
      },
      returned: 2,
      latest_seq: 43,
      oldest_seq: 42,
      latest_ts_iso: '2026-04-17T00:00:00Z',
      entries: [validEntry(), validEntry({ seq: 43, message: 'booted again' })],
    })
    expect(out.entries).toHaveLength(2)
    expect(out.entries[1]!.seq).toBe(43)
    expect(out.dashboard_surface).toBe('/api/v1/dashboard/logs')
    expect(out.source).toBe('masc_log_ring')
    expect(out.retention?.scope).toBe('dashboard_logs')
    expect(out.retention?.capacity).toBe(50000)
    expect(out.query?.applied_level).toBe('INFO')
    expect(out.latest_seq).toBe(43)
  })

  it('throws on a row missing a required field instead of silently dropping it', () => {
    expect(() =>
      parseLogsResponse({
        total: 2,
        entries: [
          validEntry(),
          { seq: 99, ts: '2026-04-17T00:01:00Z' /* missing message/source/module/level */ },
        ],
      }),
    ).toThrow(LogsSchemaDriftError)
  })

  it('rejects rows that omit level (no fallback)', () => {
    expect(() =>
      parseLogsResponse({
        total: 1,
        entries: [
          {
            seq: 1,
            ts: '2026-04-17T00:00:00Z',
            source: 'structured',
            module: '',
            message: 'bare entry',
          },
        ],
      }),
    ).toThrow(LogsSchemaDriftError)
  })

  it('tolerates a non-array entries field by returning an empty list', () => {
    const out = parseLogsResponse({ total: 0, entries: null })
    expect(out.entries).toHaveLength(0)
  })

  it('throws on a payload without total', () => {
    expect(() =>
      parseLogsResponse({ entries: [] }),
    ).toThrow(LogsSchemaDriftError)
  })

  it('throws on non-object payload', () => {
    expect(() => parseLogsResponse(null)).toThrow(LogsSchemaDriftError)
    expect(() => parseLogsResponse('not-an-object')).toThrow(LogsSchemaDriftError)
  })
})
