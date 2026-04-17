import { describe, expect, it } from 'vitest'

import {
  LogsSchemaDriftError,
  parseLogsResponse,
} from './logs'

function validEntry(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    seq: 42,
    ts: '2026-04-17T00:00:00Z',
    level: 'INFO',
    raw_level: 'INFO',
    normalized_level: 'INFO',
    source: 'structured',
    legacy_classified: false,
    module: 'Keeper',
    message: 'booted',
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

  it('drops individual entries that are missing required fields (lenient-per-entry)', () => {
    // One corrupt row must not blank the whole logs panel — matches the
    // behavior of the pre-migration decoder.
    const out = parseLogsResponse({
      total: 2,
      entries: [
        validEntry(),
        { seq: 99, ts: '2026-04-17T00:01:00Z' /* missing message */ },
      ],
    })
    expect(out.entries).toHaveLength(1)
    expect(out.entries[0]!.seq).toBe(42)
  })

  it('chains raw_level and normalized_level to level when omitted', () => {
    const out = parseLogsResponse({
      total: 1,
      entries: [validEntry({
        level: 'WARN',
        raw_level: undefined,
        normalized_level: undefined,
      })],
    })
    expect(out.entries[0]!.raw_level).toBe('WARN')
    expect(out.entries[0]!.normalized_level).toBe('WARN')
  })

  it('applies fallbacks for level/source/legacy_classified/module when backend omits them', () => {
    const out = parseLogsResponse({
      total: 1,
      entries: [
        {
          seq: 1,
          ts: '2026-04-17T00:00:00Z',
          message: 'bare entry',
        },
      ],
    })
    expect(out.entries).toHaveLength(1)
    expect(out.entries[0]!.level).toBe('INFO')
    expect(out.entries[0]!.source).toBe('structured')
    expect(out.entries[0]!.legacy_classified).toBe(false)
    expect(out.entries[0]!.module).toBe('')
    expect(out.entries[0]!.details).toBeNull()
  })

  it('defaults total to 0 when backend omits it', () => {
    const out = parseLogsResponse({ entries: [] })
    expect(out.total).toBe(0)
  })

  it('tolerates a non-array entries field by returning an empty list', () => {
    const out = parseLogsResponse({ total: 0, entries: null })
    expect(out.entries).toHaveLength(0)
  })

  it('throws on non-object payload', () => {
    expect(() => parseLogsResponse(null)).toThrow(LogsSchemaDriftError)
    expect(() => parseLogsResponse('not-an-object')).toThrow(LogsSchemaDriftError)
  })
})
