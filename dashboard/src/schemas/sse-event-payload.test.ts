import { describe, expect, it } from 'vitest'

import {
  parseOasPayload,
  parseOasPayloadOrNull,
  type TypedOasPayload,
} from './sse-event-payload'

describe('parseOasPayload', () => {
  it('parses oas:agent_started payload', () => {
    const result = parseOasPayload('oas:agent_started', {
      agent_name: 'alpha',
      task_id: 'task_42',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('agent_started')
    if (data.kind !== 'agent_started') return
    expect(data.payload.agent_name).toBe('alpha')
    expect(data.payload.task_id).toBe('task_42')
  })

  it('parses oas:agent_completed payload', () => {
    const result = parseOasPayload('oas:agent_completed', {
      agent_name: 'beta',
      task_id: 'task_99',
      elapsed_s: 12.5,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('agent_completed')
    if (data.kind !== 'agent_completed') return
    expect(data.payload.agent_name).toBe('beta')
    expect(data.payload.task_id).toBe('task_99')
    expect(data.payload.elapsed_s).toBe(12.5)
  })

  it('parses oas:agent_failed payload with error addendum', () => {
    const result = parseOasPayload('oas:agent_failed', {
      agent_name: 'gamma',
      task_id: 'task_7',
      elapsed_s: 3.0,
      error: 'boom',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('agent_failed')
    if (data.kind !== 'agent_failed') return
    expect(data.payload.agent_name).toBe('gamma')
    expect(data.payload.error).toBe('boom')
  })

  it('parses oas:tool_called payload', () => {
    const result = parseOasPayload('oas:tool_called', {
      agent_name: 'alpha',
      tool_name: 'bash',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('tool_called')
    if (data.kind !== 'tool_called') return
    expect(data.payload.tool_name).toBe('bash')
  })

  it('parses oas:tool_completed payload', () => {
    const result = parseOasPayload('oas:tool_completed', {
      agent_name: 'alpha',
      tool_name: 'bash',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('tool_completed')
    if (data.kind !== 'tool_completed') return
    expect(data.payload.agent_name).toBe('alpha')
    expect(data.payload.tool_name).toBe('bash')
  })

  it('parses oas:turn_started payload', () => {
    const result = parseOasPayload('oas:turn_started', {
      agent_name: 'alpha',
      turn: 3,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('turn_started')
    if (data.kind !== 'turn_started') return
    expect(data.payload.turn).toBe(3)
  })

  it('parses oas:turn_completed payload', () => {
    const result = parseOasPayload('oas:turn_completed', {
      agent_name: 'alpha',
      turn: 3,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('turn_completed')
    if (data.kind !== 'turn_completed') return
    expect(data.payload.turn).toBe(3)
  })

  it('parses oas:handoff_requested payload', () => {
    const result = parseOasPayload('oas:handoff_requested', {
      from_agent: 'alpha',
      to_agent: 'beta',
      reason: 'load',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('handoff_requested')
    if (data.kind !== 'handoff_requested') return
    expect(data.payload.from_agent).toBe('alpha')
    expect(data.payload.to_agent).toBe('beta')
    expect(data.payload.reason).toBe('load')
  })

  it('parses oas:handoff_completed payload', () => {
    const result = parseOasPayload('oas:handoff_completed', {
      from_agent: 'alpha',
      to_agent: 'beta',
      elapsed_s: 0.5,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('handoff_completed')
    if (data.kind !== 'handoff_completed') return
    expect(data.payload.elapsed_s).toBe(0.5)
  })

  it('parses oas:context_compacted payload', () => {
    const result = parseOasPayload('oas:context_compacted', {
      agent_name: 'alpha',
      before_tokens: 1000,
      after_tokens: 800,
      phase: 'summarize',
      runtime: 'oas-runtime',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('context_compacted')
    if (data.kind !== 'context_compacted') return
    expect(data.payload.before_tokens).toBe(1000)
    expect(data.payload.after_tokens).toBe(800)
    expect(data.payload.phase).toBe('summarize')
    expect(data.payload.runtime).toBe('oas-runtime')
  })

  it('rejects an unknown event type', () => {
    const result = parseOasPayload('oas:unknown_event', { x: 1 })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.eventType).toBe('oas:unknown_event')
  })

  it('rejects a malformed payload', () => {
    const result = parseOasPayload('oas:agent_started', {
      agent_name: 'alpha',
      task_id: 42,
    })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.message).toMatch(/task_id/)
  })

  it('rejects a missing required field', () => {
    const result = parseOasPayload('oas:agent_started', { agent_name: 'alpha' })
    expect(result.success).toBe(false)
  })

  it('returns null for parseOrNull on failure', () => {
    expect(parseOasPayloadOrNull('oas:agent_started', {})).toBeNull()
  })

  it('round-trips through write/read for every handled payload kind', () => {
    const cases: TypedOasPayload[] = [
      { kind: 'agent_started', payload: { agent_name: 'a', task_id: 't' } },
      { kind: 'agent_completed', payload: { agent_name: 'a', task_id: 't', elapsed_s: 1 } },
      { kind: 'agent_failed', payload: { agent_name: 'a', task_id: 't', elapsed_s: 1 } },
      { kind: 'tool_called', payload: { agent_name: 'a', tool_name: 'bash' } },
      { kind: 'tool_completed', payload: { agent_name: 'a', tool_name: 'bash' } },
      { kind: 'turn_started', payload: { agent_name: 'a', turn: 1 } },
      { kind: 'turn_completed', payload: { agent_name: 'a', turn: 1 } },
      {
        kind: 'handoff_requested',
        payload: { from_agent: 'a', to_agent: 'b', reason: 'r' },
      },
      {
        kind: 'handoff_completed',
        payload: { from_agent: 'a', to_agent: 'b', elapsed_s: 1 },
      },
      {
        kind: 'context_compacted',
        payload: { agent_name: 'a', before_tokens: 10, after_tokens: 5, phase: 'p' },
      },
    ]
    for (const original of cases) {
      const result = parseOasPayload(`oas:${original.kind}`, original.payload)
      expect(result.success).toBe(true)
      if (!result.success) continue
      expect(result.data.kind).toBe(original.kind)
    }
  })
})
