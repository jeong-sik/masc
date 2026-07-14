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

  it('accepts MASC wire aliases emitted by server-side SSE publishers', () => {
    expect(SSEEventTypeSchema.parse('masc/broadcast')).toBe('masc/broadcast')
    expect(SSEEventTypeSchema.parse('masc/agent_bound')).toBe('masc/agent_bound')
    expect(SSEEventTypeSchema.parse('masc/agent_unbound')).toBe('masc/agent_unbound')
  })

  it('accepts current and future oas-prefixed event types', () => {
    expect(SSEEventTypeSchema.parse('oas:agent_failed')).toBe('oas:agent_failed')
    expect(SSEEventTypeSchema.parse('oas:turn_completed')).toBe('oas:turn_completed')
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
      tool_args: { path: '/tmp/a' },
      tool_result: { ok: true },
      tool_args_preview: '{"path":"/tmp/a"}',
      tool_output_preview: '{"ok":true}',
      tool_io_redacted: false,
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

  it('accepts keeper_chat_appended with RFC-0235 audio clip', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_appended',
      name: 'keeper-1',
      connector: 'agent',
      ts_unix: 1_712_000_000,
      audio: {
        token: 'clip-123',
        mime: 'audio/mpeg',
        message_text: 'hello operator',
        audio_url: 'https://cdn.example/voice/clip-123.mp3',
        duration_sec: 5.2,
        device_id: 'dashboard',
      },
    })
    expect(r.success).toBe(true)
    if (r.success) {
      expect(r.data.audio).toEqual({
        token: 'clip-123',
        mime: 'audio/mpeg',
        message_text: 'hello operator',
        audio_url: 'https://cdn.example/voice/clip-123.mp3',
        duration_sec: 5.2,
        device_id: 'dashboard',
      })
    }
  })

  it('rejects malformed audio clip on keeper_chat_appended', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_appended',
      name: 'keeper-1',
      audio: { token: 'clip-123' },
    })
    expect(r.success).toBe(false)
  })

  it('accepts a typed Keeper chat-queue projection invalidation', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_queue_changed',
      keeper_name: 'keeper-1',
      revision: 7,
      ts_unix: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it.each([
    { type: 'keeper_chat_queue_changed', revision: 7 },
    { type: 'keeper_chat_queue_changed', keeper_name: 'keeper-1' },
    { type: 'keeper_chat_queue_changed', keeper_name: 'keeper-1', revision: -1 },
    { type: 'keeper_chat_queue_changed', keeper_name: 'keeper-1', revision: 1.5 },
    {
      type: 'keeper_chat_queue_changed',
      keeper_name: 'keeper-1',
      revision: Number.MAX_SAFE_INTEGER + 1,
    },
  ])('rejects an incomplete Keeper chat-queue invalidation: %o', value => {
    expect(SSEMessageSchema.safeParse(value).success).toBe(false)
  })
})

describe('parseSSEMessage', () => {
  it('returns the parsed message for a valid input', () => {
    const msg = parseSSEMessage({ type: 'broadcast', message: 'hi' })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('broadcast')
  })

  it('keeps MASC broadcast wire events instead of dropping them as schema drift', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({ type: 'masc/broadcast', from: 'operator', content: 'hi' })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('masc/broadcast')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps fusion_run_status events so the RFC-0266 Phase 4 live panel refresh is not dropped', () => {
    // Regression: the live WS router (sse-store.ts routeServerPushEvent ->
    // SIMPLE_ROUTES['fusion_run_status'] -> refreshFusionRuns) only sees the event
    // if it first passes this parse boundary. If this drops to null, the
    // running -> completed/failed live flip silently stops working and the panel
    // only updates on the periodic poll / tab re-navigation.
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'fusion_run_status',
      run: { run_id: 'r1', keeper: 'k', preset: 'balanced', started_at: 10, status: 'running' },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('fusion_run_status')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps unknown oas-prefixed events instead of dropping them', () => {
    const msg = parseSSEMessage({
      type: 'oas:future:event',
      payload: { revision: 1 },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('oas:future:event')
  })

  it('keeps oas telemetry tuple payloads instead of logging schema drift', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'oas:telemetry_event',
      event_type: 'telemetry_event',
      ts_unix: 1781584363.694713,
      payload: [
        'Streaming_first_chunk',
        {
          provider: 'openai_compat',
          model: 'deepseek-v4-flash',
          ttfrc_ms: 3988.802909851074,
        },
      ],
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('oas:telemetry_event')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
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
