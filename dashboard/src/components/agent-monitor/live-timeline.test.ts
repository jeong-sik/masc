import { describe, expect, it } from 'vitest'
import type { JournalEntry } from '../../types'
import { eventKindBadgeTone, eventMatchesFilter } from './live-timeline'

function entry(overrides: Partial<JournalEntry>): JournalEntry {
  return {
    agent: 'keeper-a',
    text: 'ordinary event',
    timestamp: 1712400000000,
    ...overrides,
  }
}

describe('eventMatchesFilter', () => {
  it('matches tool filter only from explicit tool event types', () => {
    expect(eventMatchesFilter(entry({ eventType: 'keeper_tool_call' }), 'tool')).toBe(true)
    expect(eventMatchesFilter(entry({ eventType: 'oas_tool' }), 'tool')).toBe(true)
  })

  it('does not treat tool-like text as a tool event', () => {
    expect(eventMatchesFilter(entry({
      eventType: 'broadcast',
      text: '```\\nkeeper_task_claim {}\\n```',
    }), 'tool')).toBe(false)
    expect(eventMatchesFilter(entry({
      eventType: 'oas_turn',
      text: 'NO_TOOL_CHANNEL: provider returned text',
    }), 'tool')).toBe(false)
  })
})

describe('eventKindBadgeTone', () => {
  it('maps heartbeat events to the ok semantic tone', () => {
    expect(eventKindBadgeTone(entry({ eventType: 'keeper_heartbeat' }))).toBe('ok')
    expect(eventKindBadgeTone(entry({ eventType: 'oas_keeper_snapshot' }))).toBe('ok')
  })

  it('maps explicit error entries to the bad semantic tone', () => {
    expect(eventKindBadgeTone(entry({
      eventType: 'broadcast',
      text: 'Error: failed to claim task',
    }))).toBe('bad')
  })

  it('maps operational events to supported semantic tones', () => {
    expect(eventKindBadgeTone(entry({ eventType: 'oas_tool' }))).toBe('warn')
    expect(eventKindBadgeTone(entry({ eventType: 'task_update' }))).toBe('ok')
    expect(eventKindBadgeTone(entry({ eventType: 'keeper_compaction' }))).toBe('warn')
  })

  it('falls back to the neutral semantic tone', () => {
    expect(eventKindBadgeTone(entry({ eventType: undefined }))).toBe('neutral')
  })
})
