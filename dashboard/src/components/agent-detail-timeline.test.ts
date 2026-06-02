import { describe, it, expect } from 'vitest'
import { timelineEventLabel } from './agent-detail-timeline'

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

