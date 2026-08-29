import { afterEach, describe, it, expect } from 'vitest'
import {
  eventKindColor,
  journalEventKindLabel,
  eventKindTone,
  keeperHealthSummary,
} from './live-store'
import { keepers } from './store'
import type { JournalEntry, Keeper } from './types'

afterEach(() => {
  keepers.value = []
})

function makeEntry(overrides: Partial<JournalEntry> = {}): JournalEntry {
  return {
    agent: 'test-agent',
    text: 'test',
    timestamp: Date.now(),
    ...overrides,
  }
}

// ================================================================
// eventKindColor
// ================================================================

describe('eventKindColor', () => {
  it('returns broadcast class for board kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'board' }))).toBe('live-event-broadcast')
  })

  it('returns task class for tasks kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'tasks' }))).toBe('live-event-task')
  })

  it('returns keeper class for keepers kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'keepers' }))).toBe('live-event-keeper')
  })

  it('returns system class for system kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'system' }))).toBe('live-event-system')
  })

  it('returns system class for agentCore kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'agentCore' }))).toBe('live-event-system')
  })

  it('returns system class when kind is undefined', () => {
    expect(eventKindColor(makeEntry({}))).toBe('live-event-system')
  })
})

// ================================================================
// eventKindTone
// ================================================================

describe('eventKindTone', () => {
  it('maps board kind to info tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'board' }))).toBe('info')
  })

  it('maps tasks kind to ok tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'tasks' }))).toBe('ok')
  })

  it('maps keepers kind to info tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'keepers' }))).toBe('info')
  })

  it('uses eventType precedence before kind fallback', () => {
    expect(eventKindTone(makeEntry({ eventType: 'broadcast' }))).toBe('info')
    expect(eventKindTone(makeEntry({ eventType: 'board_delete', kind: 'board' }))).toBe('bad')
  })

  it('falls back to neutral tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'system' }))).toBe('neutral')
    expect(eventKindTone(makeEntry({}))).toBe('neutral')
  })
})

// ================================================================
// journalEventKindLabel
// ================================================================

describe('journalEventKindLabel', () => {
  it('returns "broadcast" for broadcast eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'broadcast' }))).toBe('broadcast')
  })

  it('returns "post" for board_post eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'board_post' }))).toBe('post')
  })

  it('returns "comment" for board_comment eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'board_comment' }))).toBe('comment')
  })

  it('returns "deleted" for board_delete eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'board_delete' }))).toBe('deleted')
  })

  it('returns "heartbeat" for keeper_heartbeat eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'keeper_heartbeat' }))).toBe('heartbeat')
  })

  it('returns "handoff" for keeper_handoff eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'keeper_handoff' }))).toBe('handoff')
  })

  it('returns "phase" for keeper_phase_changed eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'keeper_phase_changed' }))).toBe('phase')
  })

  it('falls back to kind-based label for unrecognized eventType', () => {
    // board_vote has no explicit case, falls through to kind-based
    expect(journalEventKindLabel(makeEntry({ eventType: 'board_vote', kind: 'board' }))).toBe('board')
  })

  it('falls back to "task" for tasks kind without matching eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'agent_core_tool', kind: 'tasks' }))).toBe('task')
  })

  it('falls back to "keeper" for keepers kind without matching eventType', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'unknown', kind: 'keepers' }))).toBe('keeper')
  })

  it('returns "system" as final fallback', () => {
    expect(journalEventKindLabel(makeEntry({ eventType: 'agent_core_tool' }))).toBe('system')
  })

  it('returns "system" when both kind and eventType are undefined', () => {
    expect(journalEventKindLabel(makeEntry({}))).toBe('system')
  })
})

describe('keeperHealthSummary', () => {
  it('preserves unobserved context instead of reporting zero pressure', () => {
    keepers.value = [
      {
        name: 'rondo',
        status: 'active',
        keepalive_running: true,
        context_ratio: null,
      } as Keeper,
    ]

    expect(keeperHealthSummary.value.pressures).toEqual([
      {
        name: 'rondo',
        ratio: null,
        stage: 'unknown',
      },
    ])
    expect(keeperHealthSummary.value.warningCount).toBe(0)
    expect(keeperHealthSummary.value.criticalCount).toBe(0)
  })
})
