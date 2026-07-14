import { describe, expect, it } from 'vitest'

import {
  parseOasPayload,
  parseOasPayloadOrNull,
  OAS_PAYLOAD_EVENT_TYPES,
  type TypedOasPayload,
} from './sse-event-payload'
import {
  writeAgentCompletedPayload,
  writeAgentFailedPayload,
  writeAgentStartedPayload,
  writeHandoffCompletedPayload,
  writeHandoffRequestedPayload,
  writeToolCalledPayload,
  writeToolCompletedPayload,
  writeTurnCompletedPayload,
  writeTurnReadyPayload,
  writeTurnStartedPayload,
} from './sse_event_generated'

/** Full payload kind coverage used by both the round-trip sweep and the
 *  array<->union parity test.  Keeping the inventory in one place guarantees
 *  a new kind forces an update here instead of slipping through with a
 *  partial round-trip. */
const ALL_PAYLOAD_CASES: TypedOasPayload[] = [
  { kind: 'agent_started', payload: { agent_name: 'a', task_id: 't' } },
  {
    kind: 'agent_completed',
    payload: { agent_name: 'a', task_id: 't', elapsed_s: 1 },
  },
  {
    kind: 'agent_failed',
    payload: {
      agent_name: 'a',
      task_id: 't',
      elapsed_s: 1,
      error: 'boom',
      error_domain: 'api',
      error_code: 'rate_limited',
      error_retryable: true,
      error_detail: { variant: 'rate_limited', message: 'slow down' },
    },
  },
  { kind: 'tool_called', payload: { agent_name: 'a', tool_name: 'bash' } },
  { kind: 'tool_completed', payload: { agent_name: 'a', tool_name: 'bash' } },
  { kind: 'turn_started', payload: { agent_name: 'a', turn: 1 } },
  { kind: 'turn_completed', payload: { agent_name: 'a', turn: 1 } },
  {
    kind: 'turn_ready',
    payload: {
      agent_name: 'a',
      turn: 1,
      count: 2,
      names_hash: 'h',
      tool_names: ['bash', 'cat'],
    },
  },
  {
    kind: 'handoff_requested',
    payload: { from_agent: 'a', to_agent: 'b', reason: 'r' },
  },
  {
    kind: 'handoff_completed',
    payload: { from_agent: 'a', to_agent: 'b', elapsed_s: 1 },
  },
]

function serializePayload(payload: TypedOasPayload): Record<string, unknown> {
  switch (payload.kind) {
    case 'agent_started':
      return writeAgentStartedPayload(payload.payload)
    case 'agent_completed':
      return writeAgentCompletedPayload(payload.payload)
    case 'agent_failed':
      return writeAgentFailedPayload(payload.payload)
    case 'tool_called':
      return writeToolCalledPayload(payload.payload)
    case 'tool_completed':
      return writeToolCompletedPayload(payload.payload)
    case 'turn_started':
      return writeTurnStartedPayload(payload.payload)
    case 'turn_completed':
      return writeTurnCompletedPayload(payload.payload)
    case 'turn_ready':
      return writeTurnReadyPayload(payload.payload)
    case 'handoff_requested':
      return writeHandoffRequestedPayload(payload.payload)
    case 'handoff_completed':
      return writeHandoffCompletedPayload(payload.payload)
  }
}

function roundTripPayload(original: TypedOasPayload): TypedOasPayload | null {
  const raw = serializePayload(original)
  const result = parseOasPayload(`oas:${original.kind}`, raw)
  return result.success ? result.data : null
}

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

  it('parses oas:agent_failed payload with all typed error fields', () => {
    const result = parseOasPayload('oas:agent_failed', {
      agent_name: 'gamma',
      task_id: 'task_7',
      elapsed_s: 3.0,
      error: 'boom',
      error_domain: 'api',
      error_code: 'rate_limited',
      error_retryable: true,
      error_detail: { variant: 'rate_limited', message: 'slow down' },
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('agent_failed')
    if (data.kind !== 'agent_failed') return
    expect(data.payload.agent_name).toBe('gamma')
    expect(data.payload.error).toBe('boom')
    expect(data.payload.error_domain).toBe('api')
    expect(data.payload.error_code).toBe('rate_limited')
    expect(data.payload.error_retryable).toBe(true)
    expect(data.payload.error_detail).toEqual({
      variant: 'rate_limited',
      message: 'slow down',
    })
  })

  it('rejects non-string agent_failed.error via the atdgen error path', () => {
    const result = parseOasPayload('oas:agent_failed', {
      agent_name: 'gamma',
      task_id: 'task_7',
      elapsed_s: 3.0,
      error: 42,
    })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.message).toMatch(/string/)
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

  it('parses oas:turn_ready payload', () => {
    const result = parseOasPayload('oas:turn_ready', {
      agent_name: 'alpha',
      turn: 1,
      count: 2,
      names_hash: 'h',
      tool_names: ['bash'],
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    expect(result.data.kind).toBe('turn_ready')
    if (result.data.kind !== 'turn_ready') return
    expect(result.data.payload.count).toBe(2)
    expect(result.data.payload.tool_names).toEqual(['bash'])
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
    for (const original of ALL_PAYLOAD_CASES) {
      const result = roundTripPayload(original)
      expect(result, `round-trip failed for ${original.kind}`).not.toBeNull()
      expect(result?.kind).toBe(original.kind)
      expect(result?.payload).toEqual(original.payload)
    }
  })

  it('has parity between OAS_PAYLOAD_EVENT_TYPES and TypedOasPayload kind union', () => {
    const fromArray = new Set(OAS_PAYLOAD_EVENT_TYPES)
    const fromUnion = new Set(ALL_PAYLOAD_CASES.map(c => c.kind))
    expect(fromArray).toEqual(fromUnion)
  })
})
