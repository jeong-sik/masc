import { describe, expect, it } from 'vitest'
import type { LogEntry } from '../api/dashboard-logs'
import { logDisplayKind, type LogDisplayKind } from './log-classification'

function entry(overrides: Partial<LogEntry>): LogEntry {
  return {
    seq: 1,
    timestamp: '2026-08-22T00:00:00Z',
    level: 'INFO',
    source: 'structured',
    module: 'Keeper',
    keeperName: 'taskmaster',
    hasTurn: false,
    message: 'row',
    details: {},
    category: null,
    ...overrides,
  }
}

describe('logDisplayKind', () => {
  it.each<[LogEntry['category'], LogDisplayKind]>([
    ['tool', 'tool'],
    ['turn', 'turn'],
    ['lifecycle', 'lifecycle'],
    ['fsm', 'lifecycle'],
    ['heartbeat', 'lifecycle'],
    ['directive', 'approval'],
    ['boundary', 'approval'],
    ['broadcast', 'broadcast'],
    ['routine', 'log'],
    [null, 'log'],
  ])('projects category %s to the %s chip', (category, kind) => {
    expect(logDisplayKind(entry({ category }))).toBe(kind)
  })

  it('does not infer a chip from detail keys or turn_id when the producer tagged nothing', () => {
    expect(logDisplayKind(entry({ details: { tool_name: 'masc_status' } }))).toBe('log')
    expect(logDisplayKind(entry({ hasTurn: true }))).toBe('log')
    expect(logDisplayKind(entry({ category: 'fsm', hasTurn: true }))).toBe('lifecycle')
  })
})
