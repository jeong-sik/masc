import { describe, it, expect } from 'vitest'
import {
  timelineEventIcon,
  timelineEventLabel,
  timelineEventCategory,
  timelineEventSearchText,
  timelineCategoryCounts,
  filterTimelineEvents,
} from './agent-detail-timeline'
import type { AgentTimelineEvent } from '../api'

describe('timelineEventIcon', () => {
  it('returns J for joined', () => {
    expect(timelineEventIcon('joined')).toBe('J')
  })

  it('returns T for task_ prefixed types', () => {
    expect(timelineEventIcon('task_claimed')).toBe('T')
    expect(timelineEventIcon('task_started')).toBe('T')
    expect(timelineEventIcon('task_completed')).toBe('T')
    expect(timelineEventIcon('task_cancelled')).toBe('T')
    expect(timelineEventIcon('task_anything')).toBe('T')
  })

  it('returns M for broadcast', () => {
    expect(timelineEventIcon('broadcast')).toBe('M')
  })

  it('returns W for tool_call', () => {
    expect(timelineEventIcon('tool_call')).toBe('W')
  })

  it('returns E for unknown types', () => {
    expect(timelineEventIcon('unknown')).toBe('E')
    expect(timelineEventIcon('')).toBe('E')
    expect(timelineEventIcon('heartbeat')).toBe('E')
  })
})

describe('timelineEventLabel', () => {
  it('returns Korean label for joined', () => {
    expect(timelineEventLabel('joined')).toBe('참가')
  })

  it('returns Korean labels for task events', () => {
    expect(timelineEventLabel('task_claimed')).toBe('태스크 수임')
    expect(timelineEventLabel('task_started')).toBe('태스크 시작')
    expect(timelineEventLabel('task_completed')).toBe('태스크 완료')
    expect(timelineEventLabel('task_cancelled')).toBe('태스크 취소')
  })

  it('returns Korean label for broadcast', () => {
    expect(timelineEventLabel('broadcast')).toBe('공지')
  })

  it('returns Korean label for tool_call', () => {
    expect(timelineEventLabel('tool_call')).toBe('도구 호출')
  })

  it('returns the type string itself for unknown types', () => {
    expect(timelineEventLabel('unknown')).toBe('unknown')
    expect(timelineEventLabel('')).toBe('')
    expect(timelineEventLabel('custom_event')).toBe('custom_event')
  })
})

// Helpers for building fixtures.
function evt(type: string, detail: Record<string, unknown> = {}): AgentTimelineEvent {
  return { ts: '2026-04-17T01:00:00Z', type, detail }
}

describe('timelineEventCategory', () => {
  it('maps task_ prefixed types to task', () => {
    expect(timelineEventCategory('task_claimed')).toBe('task')
    expect(timelineEventCategory('task_started')).toBe('task')
    expect(timelineEventCategory('task_completed')).toBe('task')
    expect(timelineEventCategory('task_anything')).toBe('task')
  })

  it('maps known types to their own category', () => {
    expect(timelineEventCategory('tool_call')).toBe('tool_call')
    expect(timelineEventCategory('broadcast')).toBe('broadcast')
    expect(timelineEventCategory('joined')).toBe('joined')
  })

  it('maps unknown types to other', () => {
    expect(timelineEventCategory('unknown')).toBe('other')
    expect(timelineEventCategory('')).toBe('other')
    expect(timelineEventCategory('heartbeat')).toBe('other')
  })
})

describe('timelineEventSearchText', () => {
  it('includes type and Korean label', () => {
    const text = timelineEventSearchText(evt('broadcast'))
    expect(text).toContain('broadcast')
    expect(text).toContain('공지')
  })

  it('includes tool_name for tool_call events', () => {
    const text = timelineEventSearchText(evt('tool_call', { tool_name: 'bash' }))
    expect(text).toContain('bash')
  })

  it('includes title/content/error from detail', () => {
    const text = timelineEventSearchText(evt('task_completed', {
      title: 'Fix login bug',
      content: 'oauth token refresh',
      error: 'ECONNRESET',
    }))
    expect(text).toContain('fix login bug')
    expect(text).toContain('oauth')
    expect(text).toContain('econnreset')
  })

  it('returns lowercase string', () => {
    const text = timelineEventSearchText(evt('task_started', { title: 'UPPER' }))
    expect(text).toBe(text.toLowerCase())
  })

  it('ignores non-string detail fields', () => {
    const text = timelineEventSearchText(evt('tool_call', {
      tool_name: 'bash',
      duration_ms: 123,
      success: true,
    }))
    expect(text).toContain('bash')
    expect(text).not.toContain('123')
  })
})

describe('timelineCategoryCounts', () => {
  it('counts each category', () => {
    const events = [
      evt('task_claimed'),
      evt('task_started'),
      evt('tool_call'),
      evt('broadcast'),
      evt('broadcast'),
      evt('joined'),
      evt('heartbeat'),
    ]
    expect(timelineCategoryCounts(events)).toEqual({
      task: 2,
      tool_call: 1,
      broadcast: 2,
      joined: 1,
      other: 1,
    })
  })

  it('returns zeros for empty input', () => {
    expect(timelineCategoryCounts([])).toEqual({
      task: 0,
      tool_call: 0,
      broadcast: 0,
      joined: 0,
      other: 0,
    })
  })
})

describe('filterTimelineEvents', () => {
  const events: AgentTimelineEvent[] = [
    evt('task_claimed', { title: 'Deploy dashboard' }),
    evt('task_completed', { title: 'Deploy dashboard' }),
    evt('tool_call', { tool_name: 'bash' }),
    evt('tool_call', { tool_name: 'grep' }),
    evt('broadcast', { content: 'server restart scheduled' }),
    evt('joined'),
  ]

  it('returns all events when category=all and query empty', () => {
    expect(filterTimelineEvents(events, 'all', '')).toBe(events)
  })

  it('filters by category', () => {
    expect(filterTimelineEvents(events, 'task', '')).toHaveLength(2)
    expect(filterTimelineEvents(events, 'tool_call', '')).toHaveLength(2)
    expect(filterTimelineEvents(events, 'broadcast', '')).toHaveLength(1)
    expect(filterTimelineEvents(events, 'joined', '')).toHaveLength(1)
    expect(filterTimelineEvents(events, 'other', '')).toHaveLength(0)
  })

  it('filters by search query (case-insensitive)', () => {
    expect(filterTimelineEvents(events, 'all', 'deploy')).toHaveLength(2)
    expect(filterTimelineEvents(events, 'all', 'DEPLOY')).toHaveLength(2)
    expect(filterTimelineEvents(events, 'all', 'bash')).toHaveLength(1)
    expect(filterTimelineEvents(events, 'all', 'restart')).toHaveLength(1)
  })

  it('combines category and query (AND)', () => {
    expect(filterTimelineEvents(events, 'tool_call', 'bash')).toHaveLength(1)
    expect(filterTimelineEvents(events, 'task', 'deploy')).toHaveLength(2)
    expect(filterTimelineEvents(events, 'broadcast', 'bash')).toHaveLength(0)
  })

  it('trims whitespace-only query', () => {
    expect(filterTimelineEvents(events, 'all', '   ')).toHaveLength(events.length)
  })

  it('returns empty array when nothing matches', () => {
    expect(filterTimelineEvents(events, 'all', 'zzzzzz')).toEqual([])
  })
})
