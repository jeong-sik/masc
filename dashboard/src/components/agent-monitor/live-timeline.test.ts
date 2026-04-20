import { describe, expect, it } from 'vitest'
import type { JournalEntry } from '../../types'
import { eventMatchesFilter } from './live-timeline'

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
