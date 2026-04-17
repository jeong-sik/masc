import { describe, it, expect } from 'vitest'
import { timelineEventIcon, timelineEventLabel } from './agent-detail-timeline'

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
