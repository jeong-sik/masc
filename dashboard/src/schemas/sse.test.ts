import { describe, expect, it, vi } from 'vitest'
import {
  AttributionSchema,
  parseSSEMessage,
  SSEMessageSchema,
  SSEEventTypeSchema,
} from './sse'

describe('SSEEventTypeSchema', () => {
  it('accepts a known event type', () => {
    expect(SSEEventTypeSchema.parse('keeper_heartbeat')).toBe('keeper_heartbeat')
  })

  it('accepts current and future oas-prefixed event types', () => {
    expect(SSEEventTypeSchema.parse('oas:agent_failed')).toBe('oas:agent_failed')
    expect(SSEEventTypeSchema.parse('oas:context_overflow_imminent')).toBe('oas:context_overflow_imminent')
    expect(SSEEventTypeSchema.parse('oas:masc:keeper_gate')).toBe('oas:masc:keeper_gate')
    expect(SSEEventTypeSchema.parse('oas:future:event')).toBe('oas:future:event')
  })

  it('accepts audit event wire aliases', () => {
    expect(SSEEventTypeSchema.parse('audit_event')).toBe('audit_event')
    expect(SSEEventTypeSchema.parse('masc:audit_event')).toBe('masc:audit_event')
    expect(SSEEventTypeSchema.parse('oas:masc:audit_event')).toBe('oas:masc:audit_event')
  })

  it('accepts board reaction changes', () => {
    expect(SSEEventTypeSchema.parse('reaction_changed')).toBe('reaction_changed')
  })

  it('rejects an unknown event type', () => {
    const r = SSEEventTypeSchema.safeParse('this_is_not_a_real_event')
    expect(r.success).toBe(false)
  })
})

describe('AttributionSchema', () => {
  it('parses a passed outcome', () => {
    const r = AttributionSchema.safeParse({
      origin: 'det',
      gate: 'keeper_fsm',
      evidence: { note: 'ok' },
      outcome: { kind: 'passed' },
    })
    expect(r.success).toBe(true)
  })

  it('parses a partial_pass outcome with score/rationale', () => {
    const r = AttributionSchema.safeParse({
      origin: 'nondet',
      gate: 'verification',
      evidence: {},
      outcome: { kind: 'partial_pass', score: 0.75, rationale: 'mostly ok' },
    })
    expect(r.success).toBe(true)
  })

  it('rejects an unknown outcome kind', () => {
    const r = AttributionSchema.safeParse({
      origin: 'det',
      gate: 'verification',
      evidence: {},
      outcome: { kind: 'weird_kind' },
    })
    expect(r.success).toBe(false)
  })

  it('rejects partial_pass without score', () => {
    const r = AttributionSchema.safeParse({
      origin: 'det',
      gate: 'verification',
      evidence: {},
      outcome: { kind: 'partial_pass', rationale: 'x' },
    })
    expect(r.success).toBe(false)
  })
})

describe('SSEMessageSchema', () => {
  it('accepts a minimal known event', () => {
    const r = SSEMessageSchema.safeParse({ type: 'heartbeat' })
    expect(r.success).toBe(true)
    if (r.success) expect(r.data.type).toBe('heartbeat')
  })

  it('accepts a keeper_tool_call with typed fields', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_tool_call',
      keeper_name: 'k1',
      tool_name: 'bash',
      duration_ms: 1234,
      success: true,
    })
    expect(r.success).toBe(true)
  })

  it('rejects wrong type on a known field', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_tool_call',
      duration_ms: 'not_a_number',
    })
    expect(r.success).toBe(false)
  })

  it('rejects malformed board post kind metadata at the SSE boundary', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'post_created',
      post_id: 'post-1',
      post_kind: 1,
    })
    expect(r.success).toBe(false)
  })

  it('accepts typed board reaction metadata at the SSE boundary', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'reaction_changed',
      target_type: 'comment',
      target_id: 'comment-1',
      user_id: 'dashboard-reviewer',
      emoji: '🚀',
      reacted: true,
    })
    expect(r.success).toBe(true)
  })

  it('rejects malformed board reaction metadata at the SSE boundary', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'reaction_changed',
      target_type: 'post',
      target_id: 'post-1',
      reacted: 'yes',
    })
    expect(r.success).toBe(false)
  })

  it('rejects missing type discriminator', () => {
    const r = SSEMessageSchema.safeParse({ agent: 'nobody' })
    expect(r.success).toBe(false)
  })

  it('passes through unknown fields (forward-compat)', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'heartbeat',
      some_new_backend_field: 42,
    })
    expect(r.success).toBe(true)
  })

  it('parses an OAS event with attribution envelope', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'oas:turn_completed',
      correlation_id: 'abc',
      run_id: 'r1',
      attribution: {
        origin: 'det',
        gate: 'oas_completion',
        evidence: { reason: 'ok' },
        outcome: { kind: 'passed' },
      },
    })
    expect(r.success).toBe(true)
  })
})

describe('parseSSEMessage', () => {
  it('returns the parsed message for a valid input', () => {
    const msg = parseSSEMessage({ type: 'broadcast', message: 'hi' })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('broadcast')
  })

  it('keeps unknown oas-prefixed events instead of dropping them', () => {
    const msg = parseSSEMessage({
      type: 'oas:slot_scheduler_observed',
      payload: { state: 'saturated', active: 3, max_slots: 3 },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('oas:slot_scheduler_observed')
  })

  it('silently ignores MCP JSON-RPC control notifications on the SSE stream', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage({
      jsonrpc: '2.0',
      method: 'notifications/tools/list_changed',
    })).toBeNull()
    expect(parseSSEMessage({
      jsonrpc: '2.0',
      method: 'notifications/resources/updated',
      params: { uri: 'status.json' },
    })).toBeNull()
    expect(parseSSEMessage({
      jsonrpc: '2.0',
      method: 'notifications/message',
      params: { level: 'info', data: 'ready' },
    })).toBeNull()
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('still warns when a dashboard board notification is missing its event type', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage({
      jsonrpc: '2.0',
      method: 'notifications/board',
      params: { post_id: 'p1' },
    })).toBeNull()
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })

  it('returns null and warns on invalid input', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({ type: 'not_a_real_type' })
    expect(msg).toBeNull()
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })

  it('returns null for a non-object payload', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage('just a string')).toBeNull()
    expect(parseSSEMessage(42)).toBeNull()
    expect(parseSSEMessage(null)).toBeNull()
    warnSpy.mockRestore()
  })
})
