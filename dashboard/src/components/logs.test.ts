import { describe, expect, it } from 'vitest'
import type { LogEntry } from '../api/dashboard'
import { mergeLogEntries } from './logs'

function entry(seq: number, overrides: Partial<LogEntry> = {}): LogEntry {
  return {
    seq,
    ts: `2026-03-24T00:00:${String(seq).padStart(2, '0')}Z`,
    level: 'INFO',
    raw_level: 'INFO',
    normalized_level: 'INFO',
    source: 'structured',
    legacy_classified: false,
    module: 'Dashboard',
    message: `entry-${seq}`,
    details: null,
    ...overrides,
  }
}

describe('mergeLogEntries', () => {
  it('deduplicates by seq and keeps newest payload', () => {
    const current = [entry(5, { message: 'old-5' }), entry(4)]
    const incoming = [entry(6), entry(5, { message: 'new-5', source: 'legacy_stderr' })]

    expect(mergeLogEntries(current, incoming, 10)).toEqual([
      entry(6),
      entry(5, { message: 'new-5', source: 'legacy_stderr' }),
      entry(4),
    ])
  })

  it('trims merged output to the requested maximum', () => {
    const current = [entry(4), entry(3), entry(2)]
    const incoming = [entry(5), entry(1)]

    expect(mergeLogEntries(current, incoming, 3).map(item => item.seq)).toEqual([5, 4, 3])
  })
})
