import { describe, it, expect } from 'vitest'
import { journalKindIcon } from './agent-detail-state'
import type { JournalEntry } from '../types/sse'

function makeEntry(kind?: string): JournalEntry {
  return {
    agent: 'test',
    text: 'test entry',
    timestamp: Date.now(),
    kind: kind as JournalEntry['kind'],
  }
}

// ================================================================
// journalKindIcon
// ================================================================

describe('journalKindIcon', () => {
  it('returns B for board', () => {
    expect(journalKindIcon(makeEntry('board'))).toBe('B')
  })

  it('returns T for tasks', () => {
    expect(journalKindIcon(makeEntry('tasks'))).toBe('T')
  })

  it('returns K for keepers', () => {
    expect(journalKindIcon(makeEntry('keepers'))).toBe('K')
  })

  it('returns S for system', () => {
    expect(journalKindIcon(makeEntry('system'))).toBe('S')
  })

  it('returns S for undefined kind', () => {
    expect(journalKindIcon(makeEntry())).toBe('S')
  })

  it('returns S for unknown kind', () => {
    expect(journalKindIcon(makeEntry('oas'))).toBe('S')
  })
})
