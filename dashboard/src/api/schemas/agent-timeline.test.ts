import { describe, expect, it } from 'vitest'

import {
  AgentTimelineSchemaDriftError,
  parseAgentTimelineResponse,
} from './agent-timeline'

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    agent: 'dreamer',
    period: { from: '2026-04-17T00:00:00Z', to: '2026-04-17T04:00:00Z' },
    events: [
      {
        ts: '2026-04-17T00:05:00Z',
        type: 'task_claimed',
        detail: { task_id: 'T-1' },
      },
      {
        ts: '2026-04-17T00:10:00Z',
        type: 'tool_call',
        detail: { tool: 'masc_check', duration_ms: 42 },
      },
    ],
    summary: {
      tasks_completed: 3,
      tasks_claimed: 4,
      messages_sent: 12,
      tool_calls: 7,
      active_duration_minutes: 38,
      total_events: 24,
    },
    ...overrides,
  }
}

describe('parseAgentTimelineResponse', () => {
  it('accepts a well-formed response', () => {
    const out = parseAgentTimelineResponse(validResponse())
    expect(out.agent).toBe('dreamer')
    expect(out.events).toHaveLength(2)
    expect(out.summary.tool_calls).toBe(7)
  })

  it('accepts a response with no events', () => {
    const out = parseAgentTimelineResponse(
      validResponse({
        events: [],
        summary: {
          tasks_completed: 0,
          tasks_claimed: 0,
          messages_sent: 0,
          active_duration_minutes: 0,
          total_events: 0,
        },
      }),
    )
    expect(out.events).toHaveLength(0)
  })

  it('accepts omitted optional tool_calls field', () => {
    const out = parseAgentTimelineResponse(
      validResponse({
        summary: {
          tasks_completed: 1,
          tasks_claimed: 1,
          messages_sent: 0,
          active_duration_minutes: 10,
          total_events: 2,
        },
      }),
    )
    expect(out.summary.tool_calls).toBeUndefined()
  })

  it('accepts unknown event types (backend evolves event taxonomy)', () => {
    const out = parseAgentTimelineResponse(
      validResponse({
        events: [
          {
            ts: '2026-04-17T00:00:00Z',
            type: 'brand_new_event_kind',
            detail: {},
          },
        ],
      }),
    )
    expect(out.events[0]!.type).toBe('brand_new_event_kind')
  })

  it('throws when summary is missing required fields', () => {
    const bad = validResponse({
      summary: { tasks_completed: 0 },
    })
    expect(() => parseAgentTimelineResponse(bad)).toThrow(AgentTimelineSchemaDriftError)
  })

  it('throws when period shape is wrong', () => {
    const bad = validResponse({ period: { from: '2026-04-17T00:00:00Z' } })
    expect(() => parseAgentTimelineResponse(bad)).toThrow(AgentTimelineSchemaDriftError)
  })

  it('throws when events has an entry missing ts', () => {
    const bad = validResponse({
      events: [{ type: 'task_claimed', detail: {} }],
    })
    expect(() => parseAgentTimelineResponse(bad)).toThrow(AgentTimelineSchemaDriftError)
  })

  it('throws on non-object payload', () => {
    expect(() => parseAgentTimelineResponse(null)).toThrow(AgentTimelineSchemaDriftError)
  })
})
