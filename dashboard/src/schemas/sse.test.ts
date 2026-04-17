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
