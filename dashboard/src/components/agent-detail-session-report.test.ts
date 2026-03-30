import { describe, expect, it } from 'vitest'
import {
  extractBroadcasts,
  extractTaskEvents,
  groupBroadcastsIntoReports,
} from './agent-detail-session-report'
import type { AgentTimelineEvent } from '../api'

function makeEvent(type: string, detail: Record<string, unknown>, ts = '2026-03-30T10:00:00Z'): AgentTimelineEvent {
  return { type, detail, ts }
}

describe('extractBroadcasts', () => {
  it('filters only broadcast events with content > 20 chars', () => {
    const events: AgentTimelineEvent[] = [
      makeEvent('broadcast', { content: 'This is a meaningful broadcast message about work done' }),
      makeEvent('broadcast', { content: 'short' }),
      makeEvent('task_completed', { title: 'some task' }),
      makeEvent('broadcast', { content: 12345 }), // non-string content
      makeEvent('broadcast', { content: 'Another meaningful message about analysis results' }),
    ]
    const result = extractBroadcasts(events)
    expect(result).toHaveLength(2)
    expect(result[0]!.detail.content).toBe('This is a meaningful broadcast message about work done')
    expect(result[1]!.detail.content).toBe('Another meaningful message about analysis results')
  })

  it('returns empty array when no broadcasts exist', () => {
    const events: AgentTimelineEvent[] = [
      makeEvent('task_completed', { title: 'task' }),
      makeEvent('joined', {}),
    ]
    expect(extractBroadcasts(events)).toEqual([])
  })

  it('handles missing content field gracefully', () => {
    const events: AgentTimelineEvent[] = [
      makeEvent('broadcast', {}),
      makeEvent('broadcast', { other: 'field' }),
    ]
    expect(extractBroadcasts(events)).toEqual([])
  })
})

describe('extractTaskEvents', () => {
  it('filters events starting with task_', () => {
    const events: AgentTimelineEvent[] = [
      makeEvent('task_completed', { title: 'A' }),
      makeEvent('broadcast', { content: 'msg' }),
      makeEvent('task_claimed', { title: 'B' }),
      makeEvent('joined', {}),
      makeEvent('task_cancelled', { title: 'C' }),
    ]
    const result = extractTaskEvents(events)
    expect(result).toHaveLength(3)
    expect(result.map(e => e.type)).toEqual(['task_completed', 'task_claimed', 'task_cancelled'])
  })
})

describe('groupBroadcastsIntoReports', () => {
  it('returns empty array for empty input', () => {
    expect(groupBroadcastsIntoReports([])).toEqual([])
  })

  it('creates one report per broadcast when gaps > 60s', () => {
    const broadcasts: AgentTimelineEvent[] = [
      makeEvent('broadcast', { content: 'First report' }, '2026-03-30T10:00:00Z'),
      makeEvent('broadcast', { content: 'Second report' }, '2026-03-30T10:02:00Z'),
      makeEvent('broadcast', { content: 'Third report' }, '2026-03-30T10:05:00Z'),
    ]
    const result = groupBroadcastsIntoReports(broadcasts)
    expect(result).toHaveLength(3)
    expect(result[0]!.content).toBe('First report')
    expect(result[1]!.content).toBe('Second report')
    expect(result[2]!.content).toBe('Third report')
  })

  it('merges broadcasts within 60 seconds of each other', () => {
    const broadcasts: AgentTimelineEvent[] = [
      makeEvent('broadcast', { content: 'Part 1' }, '2026-03-30T10:00:00Z'),
      makeEvent('broadcast', { content: 'Part 2' }, '2026-03-30T10:00:30Z'),
      makeEvent('broadcast', { content: 'Part 3' }, '2026-03-30T10:00:50Z'),
    ]
    const result = groupBroadcastsIntoReports(broadcasts)
    expect(result).toHaveLength(1)
    expect(result[0]!.content).toBe('Part 1\n\n---\n\nPart 2\n\n---\n\nPart 3')
    expect(result[0]!.ts).toBe('2026-03-30T10:00:00Z')
  })

  it('correctly handles chain: each <60s from previous but >60s from start', () => {
    // 0s, 40s, 80s — each is <60s from previous, should all merge
    const broadcasts: AgentTimelineEvent[] = [
      makeEvent('broadcast', { content: 'A' }, '2026-03-30T10:00:00Z'),
      makeEvent('broadcast', { content: 'B' }, '2026-03-30T10:00:40Z'),
      makeEvent('broadcast', { content: 'C' }, '2026-03-30T10:01:20Z'),
    ]
    const result = groupBroadcastsIntoReports(broadcasts)
    expect(result).toHaveLength(1)
    expect(result[0]!.content).toContain('A')
    expect(result[0]!.content).toContain('B')
    expect(result[0]!.content).toContain('C')
  })

  it('splits when gap from previous exceeds 60s', () => {
    const broadcasts: AgentTimelineEvent[] = [
      makeEvent('broadcast', { content: 'Group1-A' }, '2026-03-30T10:00:00Z'),
      makeEvent('broadcast', { content: 'Group1-B' }, '2026-03-30T10:00:30Z'),
      makeEvent('broadcast', { content: 'Group2-A' }, '2026-03-30T10:02:00Z'),
    ]
    const result = groupBroadcastsIntoReports(broadcasts)
    expect(result).toHaveLength(2)
    expect(result[0]!.content).toContain('Group1-A')
    expect(result[0]!.content).toContain('Group1-B')
    expect(result[1]!.content).toBe('Group2-A')
  })
})
