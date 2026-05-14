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
      entries: [validEntry(), validEntry({ seq: 43, message: 'booted again' })],
    })
    expect(out.entries).toHaveLength(2)
    expect(out.entries[1]!.seq).toBe(43)
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
