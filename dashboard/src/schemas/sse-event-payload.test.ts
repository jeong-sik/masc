import { describe, expect, it } from 'vitest'

import {
  parseAgentCorePayload,
  parseAgentCorePayloadOrNull,
  AGENT_CORE_PAYLOAD_EVENT_TYPES,
  type TypedAgentCorePayload,
} from './sse-event-payload'
import {
  writeAgentCompletedPayload,
  writeAgentFailedPayload,
  writeAgentInputRequiredPayload,
  writeAgentStartedPayload,
  writeAgentYieldedPayload,
  writeContentReplacementKeptPayload,
  writeContentReplacementReplacedPayload,
  writeContextCompactStartedPayload,
  writeContextCompactedPayload,
  writeHandoffCompletedPayload,
  writeHandoffRequestedPayload,
  writeSlotSchedulerObservedPayload,
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
const ALL_PAYLOAD_CASES: TypedAgentCorePayload[] = [
  { kind: 'agent_started', payload: { agent_name: 'a', task_id: 't' } },
  {
    kind: 'agent_completed',
    payload: { agent_name: 'a', task_id: 't', elapsed_s: 1 },
  },
  {
    kind: 'agent_yielded',
    payload: { agent_name: 'a', task_id: 't', turn: 1, elapsed_s: 1 },
  },
  {
    kind: 'agent_input_required',
    payload: {
      agent_name: 'a',
      task_id: 't',
      elapsed_s: 1,
      request_id: 'request-1',
      participant_name: 'operator',
      question: 'Continue?',
      schema: null,
      timeout_s: null,
      created_at: 1,
    },
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
  {
    kind: 'context_compacted',
    payload: {
      agent_name: 'a',
      before_tokens: 10,
      after_tokens: 5,
      phase: 'p',
    },
  },
  {
    kind: 'context_compact_started',
    payload: { agent_name: 'a', trigger: 'threshold' },
  },
  {
    kind: 'content_replacement_replaced',
    payload: {
      tool_use_id: 'tu1',
      preview: 'preview',
      original_chars: 100,
      seen_count_after: 1,
    },
  },
  {
    kind: 'content_replacement_kept',
    payload: { tool_use_id: 'tu1', seen_count_after: 1 },
  },
  {
    kind: 'slot_scheduler_observed',
    payload: {
      max_slots: 4,
      active: 2,
      available: 2,
      queue_length: 0,
      state: 'healthy',
    },
  },
]

function serializePayload(payload: TypedAgentCorePayload): Record<string, unknown> {
  switch (payload.kind) {
    case 'agent_started':
      return writeAgentStartedPayload(payload.payload)
    case 'agent_completed':
      return writeAgentCompletedPayload(payload.payload)
    case 'agent_yielded':
      return writeAgentYieldedPayload(payload.payload)
    case 'agent_input_required':
      return writeAgentInputRequiredPayload(payload.payload)
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
    case 'context_compacted':
      return writeContextCompactedPayload(payload.payload)
    case 'context_compact_started':
      return writeContextCompactStartedPayload(payload.payload)
    case 'content_replacement_replaced':
      return writeContentReplacementReplacedPayload(payload.payload)
    case 'content_replacement_kept':
      return writeContentReplacementKeptPayload(payload.payload)
    case 'slot_scheduler_observed':
      return writeSlotSchedulerObservedPayload(payload.payload)
  }
}

function roundTripPayload(original: TypedAgentCorePayload): TypedAgentCorePayload | null {
  const raw = serializePayload(original)
  const result = parseAgentCorePayload(`agent_core:${original.kind}`, raw)
  return result.success ? result.data : null
}

describe('parseAgentCorePayload', () => {
  it('parses agent_core:agent_started payload', () => {
    const result = parseAgentCorePayload('agent_core:agent_started', {
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

  it('parses agent_core:agent_completed payload', () => {
    const result = parseAgentCorePayload('agent_core:agent_completed', {
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

  it('parses agent_core:agent_yielded without projecting completion', () => {
    const result = parseAgentCorePayload('agent_core:agent_yielded', {
      agent_name: 'beta',
      task_id: 'task_99',
      turn: 3,
      elapsed_s: 12.5,
    })
    expect(result.success).toBe(true)
    if (!result.success || result.data.kind !== 'agent_yielded') return
    expect(result.data.payload).toEqual({
      agent_name: 'beta',
      task_id: 'task_99',
      turn: 3,
      elapsed_s: 12.5,
    })
  })

  it('parses agent_core:agent_input_required with the typed request', () => {
    const result = parseAgentCorePayload('agent_core:agent_input_required', {
      agent_name: 'beta',
      task_id: 'task_99',
      elapsed_s: 12.5,
      request_id: 'request-1',
      participant_name: 'operator',
      question: 'Continue?',
      schema: { type: 'boolean' },
      timeout_s: 30,
      created_at: 1_000,
    })
    expect(result.success).toBe(true)
    if (!result.success || result.data.kind !== 'agent_input_required') return
    expect(result.data.payload.request_id).toBe('request-1')
    expect(result.data.payload.question).toBe('Continue?')
    expect(result.data.payload.schema).toEqual({ type: 'boolean' })
  })

  it('rejects malformed non-terminal agent outcomes', () => {
    expect(parseAgentCorePayload('agent_core:agent_yielded', {
      agent_name: 'beta',
      task_id: 'task_99',
      turn: '3',
      elapsed_s: 12.5,
    }).success).toBe(false)
    expect(parseAgentCorePayload('agent_core:agent_input_required', {
      agent_name: 'beta',
      task_id: 'task_99',
      elapsed_s: 12.5,
      request_id: 'request-1',
      participant_name: null,
      question: 42,
      schema: null,
      timeout_s: null,
      created_at: 1_000,
    }).success).toBe(false)
  })

  it('parses agent_core:agent_failed payload with all typed error fields', () => {
    const result = parseAgentCorePayload('agent_core:agent_failed', {
      agent_name: 'gamma',
      task_id: 'task_7',
      elapsed_s: 3.0,
      error: 'boom',
      error_domain: 'api',
      error_code: 'rate_limited',
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
    expect(data.payload.error_detail).toEqual({
      variant: 'rate_limited',
      message: 'slow down',
    })
  })

  it('rejects non-string agent_failed.error via the atdgen error path', () => {
    const result = parseAgentCorePayload('agent_core:agent_failed', {
      agent_name: 'gamma',
      task_id: 'task_7',
      elapsed_s: 3.0,
      error: 42,
    })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.message).toMatch(/string/)
  })

  it('parses agent_core:tool_called payload', () => {
    const result = parseAgentCorePayload('agent_core:tool_called', {
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

  it('parses agent_core:tool_completed payload', () => {
    const result = parseAgentCorePayload('agent_core:tool_completed', {
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

  it('parses agent_core:turn_started payload', () => {
    const result = parseAgentCorePayload('agent_core:turn_started', {
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

  it('parses agent_core:turn_completed payload', () => {
    const result = parseAgentCorePayload('agent_core:turn_completed', {
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

  it('parses agent_core:turn_ready payload', () => {
    const result = parseAgentCorePayload('agent_core:turn_ready', {
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

  it('parses agent_core:handoff_requested payload', () => {
    const result = parseAgentCorePayload('agent_core:handoff_requested', {
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

  it('parses agent_core:handoff_completed payload', () => {
    const result = parseAgentCorePayload('agent_core:handoff_completed', {
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

  it('parses agent_core:context_compacted to the 4 wire fields and does not surface an unmodeled runtime', () => {
    // The context_compacted wire format has exactly 4 fields
    // (lib/sse_event/sse_event.atd context_compacted_payload). A stray runtime
    // key on the wire must be ignored, not surfaced as a phantom field.
    const result = parseAgentCorePayload('agent_core:context_compacted', {
      agent_name: 'alpha',
      before_tokens: 1000,
      after_tokens: 800,
      phase: 'summarize',
      runtime: 'agent-core-runtime',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    const { data } = result
    expect(data.kind).toBe('context_compacted')
    if (data.kind !== 'context_compacted') return
    expect(data.payload.before_tokens).toBe(1000)
    expect(data.payload.after_tokens).toBe(800)
    expect(data.payload.phase).toBe('summarize')
    expect('runtime' in data.payload).toBe(false)
  })

  it('parses agent_core:context_compact_started payload', () => {
    const result = parseAgentCorePayload('agent_core:context_compact_started', {
      agent_name: 'alpha',
      trigger: 'threshold',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    expect(result.data.kind).toBe('context_compact_started')
    if (result.data.kind !== 'context_compact_started') return
    expect(result.data.payload.trigger).toBe('threshold')
  })

  it('parses agent_core:content_replacement_replaced payload', () => {
    const result = parseAgentCorePayload('agent_core:content_replacement_replaced', {
      tool_use_id: 'tu1',
      preview: 'preview',
      original_chars: 100,
      seen_count_after: 1,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    expect(result.data.kind).toBe('content_replacement_replaced')
    if (result.data.kind !== 'content_replacement_replaced') return
    expect(result.data.payload.preview).toBe('preview')
  })

  it('parses agent_core:content_replacement_kept payload', () => {
    const result = parseAgentCorePayload('agent_core:content_replacement_kept', {
      tool_use_id: 'tu1',
      seen_count_after: 1,
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    expect(result.data.kind).toBe('content_replacement_kept')
    if (result.data.kind !== 'content_replacement_kept') return
    expect(result.data.payload.seen_count_after).toBe(1)
  })

  it('parses agent_core:slot_scheduler_observed payload', () => {
    const result = parseAgentCorePayload('agent_core:slot_scheduler_observed', {
      max_slots: 4,
      active: 2,
      available: 2,
      queue_length: 0,
      state: 'healthy',
    })
    expect(result.success).toBe(true)
    if (!result.success) return
    expect(result.data.kind).toBe('slot_scheduler_observed')
    if (result.data.kind !== 'slot_scheduler_observed') return
    expect(result.data.payload.state).toBe('healthy')
  })

  it('rejects an unknown event type', () => {
    const result = parseAgentCorePayload('agent_core:unknown_event', { x: 1 })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.eventType).toBe('agent_core:unknown_event')
  })

  it('rejects a malformed payload', () => {
    const result = parseAgentCorePayload('agent_core:agent_started', {
      agent_name: 'alpha',
      task_id: 42,
    })
    expect(result.success).toBe(false)
    if (result.success) return
    expect(result.error.issues[0]?.message).toMatch(/task_id/)
  })

  it('rejects a missing required field', () => {
    const result = parseAgentCorePayload('agent_core:agent_started', { agent_name: 'alpha' })
    expect(result.success).toBe(false)
  })

  it('returns null for parseOrNull on failure', () => {
    expect(parseAgentCorePayloadOrNull('agent_core:agent_started', {})).toBeNull()
  })

  it('round-trips through write/read for every handled payload kind', () => {
    for (const original of ALL_PAYLOAD_CASES) {
      const result = roundTripPayload(original)
      expect(result, `round-trip failed for ${original.kind}`).not.toBeNull()
      expect(result?.kind).toBe(original.kind)
      expect(result?.payload).toEqual(original.payload)
    }
  })

  it('has parity between AGENT_CORE_PAYLOAD_EVENT_TYPES and TypedAgentCorePayload kind union', () => {
    const fromArray = new Set(AGENT_CORE_PAYLOAD_EVENT_TYPES)
    const fromUnion = new Set(ALL_PAYLOAD_CASES.map(c => c.kind))
    expect(fromArray).toEqual(fromUnion)
  })
})
