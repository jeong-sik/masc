import { describe, it, expect } from 'vitest'
import { eventKindColor, eventKindLabel, eventKindTone } from './live-store'
import type { JournalEntry } from './types'

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

  it('returns system class for oas kind', () => {
    expect(eventKindColor(makeEntry({ kind: 'oas' }))).toBe('live-event-system')
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

  it('maps keepers kind to select tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'keepers' }))).toBe('select')
  })

  it('falls back to neutral tone', () => {
    expect(eventKindTone(makeEntry({ kind: 'system' }))).toBe('neutral')
    expect(eventKindTone(makeEntry({}))).toBe('neutral')
  })
})

// ================================================================
// eventKindLabel
// ================================================================

describe('eventKindLabel', () => {
  it('returns "broadcast" for broadcast eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'broadcast' }))).toBe('broadcast')
  })

  it('returns "joined" for agent_joined eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'agent_joined' }))).toBe('joined')
  })

  it('returns "left" for agent_left eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'agent_left' }))).toBe('left')
  })

  it('returns "task" for task_update eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'task_update' }))).toBe('task')
  })

  it('returns "post" for board_post eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'board_post' }))).toBe('post')
  })

  it('returns "comment" for board_comment eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'board_comment' }))).toBe('comment')
  })

  it('returns "deleted" for board_delete eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'board_delete' }))).toBe('deleted')
  })

  it('returns "heartbeat" for keeper_heartbeat eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'keeper_heartbeat' }))).toBe('heartbeat')
  })

  it('returns "handoff" for keeper_handoff eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'keeper_handoff' }))).toBe('handoff')
  })

  it('returns "compact" for keeper_compaction eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'keeper_compaction' }))).toBe('compact')
  })

  it('returns "guardrail" for keeper_guardrail eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'keeper_guardrail' }))).toBe('guardrail')
  })

  it('returns "phase" for keeper_phase_changed eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'keeper_phase_changed' }))).toBe('phase')
  })

  it('falls back to kind-based label for unrecognized eventType', () => {
    // board_vote has no explicit case, falls through to kind-based
    expect(eventKindLabel(makeEntry({ eventType: 'board_vote', kind: 'board' }))).toBe('board')
  })

  it('falls back to "task" for tasks kind without matching eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'oas_task', kind: 'tasks' }))).toBe('task')
  })

  it('falls back to "keeper" for keepers kind without matching eventType', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'oas_keeper_snapshot', kind: 'keepers' }))).toBe('keeper')
  })

  it('returns "system" as final fallback', () => {
    expect(eventKindLabel(makeEntry({ eventType: 'oas_tool' }))).toBe('system')
  })

  it('returns "system" when both kind and eventType are undefined', () => {
    expect(eventKindLabel(makeEntry({}))).toBe('system')
  })
})
