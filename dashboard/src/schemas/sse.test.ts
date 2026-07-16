import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  _testResetSseSchemaDriftLog,
  AttributionSchema,
  parseSSEMessage,
  SSEMessageSchema,
  SSEEventTypeSchema,
} from './sse'

beforeEach(() => {
  _testResetSseSchemaDriftLog()
})

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
      disposition: 'completed',
      tool_args: { path: '/tmp/a' },
      tool_result: { ok: true },
      tool_args_preview: '{"path":"/tmp/a"}',
      tool_output_preview: '{"ok":true}',
      tool_io_redacted: false,
    })
    expect(r.success).toBe(true)
  })

  it('rejects a keeper_tool_call without canonical disposition', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_tool_call',
      tool_name: 'bash',
      duration_ms: 1234,
      success: true,
    })
    expect(r.success).toBe(false)
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

  it('accepts a goal_loop_status event with an object payload', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'goal_loop_status',
      payload: { overall_status: 'on_track', loop_iteration: 4 },
      ts_unix: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it('rejects a goal_loop_status event with a non-object payload', () => {
    const r = SSEMessageSchema.safeParse({ type: 'goal_loop_status', payload: 'not an object' })
    expect(r.success).toBe(false)
  })

  it('accepts a gate_mode_changed event with a null previous_mode', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'gate_mode_changed',
      mode: 'supervised',
      previous_mode: null,
      actor: 'operator',
      changed_at: '2026-07-15T00:00:00Z',
    })
    expect(r.success).toBe(true)
  })

  it('accepts a gate_mode_changed event with a string previous_mode', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'gate_mode_changed',
      mode: 'autonomous',
      previous_mode: 'supervised',
      actor: 'operator',
      changed_at: '2026-07-15T00:00:00Z',
    })
    expect(r.success).toBe(true)
  })

  it('rejects a gate_mode_changed event with a non-string mode', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'gate_mode_changed',
      mode: 1,
      actor: 'operator',
      changed_at: '2026-07-15T00:00:00Z',
    })
    expect(r.success).toBe(false)
  })

  it('accepts a masc/task_claimed event with auto-released task ids', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'masc/task_claimed',
      task_id: 'task-1',
      agent_name: 'claude',
      auto_released_task_ids: ['task-0'],
      timestamp: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it('accepts a masc/task_claimed event with no auto-released task ids', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'masc/task_claimed',
      task_id: 'task-1',
      agent_name: 'claude',
      auto_released_task_ids: [],
      timestamp: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it.each([
    { type: 'masc/task_claimed', agent_name: 'claude', auto_released_task_ids: [] },
    { type: 'masc/task_claimed', task_id: 'task-1', auto_released_task_ids: [] },
    { type: 'masc/task_claimed', task_id: 'task-1', agent_name: 'claude', auto_released_task_ids: 'not-an-array' },
    { type: 'masc/task_claimed', task_id: 'task-1', agent_name: 'claude', auto_released_task_ids: [1, 2] },
  ])('rejects a malformed masc/task_claimed event: %o', value => {
    expect(SSEMessageSchema.safeParse(value).success).toBe(false)
  })

  it('accepts an approval:summary_updated event with a record payload', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'approval:summary_updated',
      payload: { id: 'req-1', summary_status: 'approved' },
    })
    expect(r.success).toBe(true)
  })

  it('rejects an approval:summary_updated event with a non-object payload', () => {
    const r = SSEMessageSchema.safeParse({ type: 'approval:summary_updated', payload: 'not an object' })
    expect(r.success).toBe(false)
  })

  it('accepts a dashboard_yjs_update event with a string payload', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'dashboard_yjs_update',
      kind: 'keeper_update',
      payload: '{"kind":"keeper_update","keeper_name":"k1"}',
      payload_len: 42,
      frame_base64: 'AAEAAAAAAAA=',
      encoding: 'yjs_update_v1_base64',
    })
    expect(r.success).toBe(true)
  })

  it.each([
    // record payload instead of the required JSON-encoded string
    {
      type: 'dashboard_yjs_update',
      kind: 'keeper_update',
      payload: { kind: 'keeper_update' },
      payload_len: 10,
      frame_base64: 'AA==',
      encoding: 'yjs_update_v1_base64',
    },
    // missing frame_base64
    { type: 'dashboard_yjs_update', kind: 'keeper_update', payload: '{}', payload_len: 2 },
    // negative payload_len
    {
      type: 'dashboard_yjs_update',
      kind: 'keeper_update',
      payload: '{}',
      payload_len: -1,
      frame_base64: 'AA==',
      encoding: 'yjs_update_v1_base64',
    },
  ])('rejects a malformed dashboard_yjs_update event: %o', value => {
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

  it('keeps dashboard_yjs_update events instead of dropping them as schema drift', () => {
    // Regression: before this fix, `payload` here (a JSON-stringified string)
    // tripped the generic "payload must be a record" rule and every Yjs
    // telemetry frame was silently dropped.
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'dashboard_yjs_update',
      kind: 'keeper_update',
      payload: '{"kind":"keeper_update","keeper_name":"k1"}',
      payload_len: 42,
      frame_base64: 'AAEAAAAAAAA=',
      encoding: 'yjs_update_v1_base64',
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('dashboard_yjs_update')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps gate_mode_changed events instead of dropping them as schema drift', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'gate_mode_changed',
      mode: 'supervised',
      previous_mode: null,
      actor: 'operator',
      changed_at: '2026-07-15T00:00:00Z',
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('gate_mode_changed')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps masc/task_claimed events so the execution panel refresh is not dropped', () => {
    // Regression: sse-store.ts PREFIX_ROUTES already routes 'masc/task_' to
    // the execution refresh target; it only ever saw the event if this parse
    // boundary let it through.
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'masc/task_claimed',
      task_id: 'task-1',
      agent_name: 'claude',
      auto_released_task_ids: [],
      timestamp: 1_712_000_000,
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('masc/task_claimed')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps approval:summary_updated events instead of dropping them as schema drift', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'approval:summary_updated',
      payload: { id: 'req-1', summary_status: 'approved' },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('approval:summary_updated')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps goal_loop_status events so the live goal-loop delta is not dropped', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'goal_loop_status',
      payload: { overall_status: 'on_track', loop_iteration: 4 },
      ts_unix: 1_712_000_000,
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('goal_loop_status')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps unknown oas-prefixed events instead of dropping them', () => {
    const msg = parseSSEMessage({
      type: 'oas:slot_scheduler_observed',
      payload: { state: 'saturated', active: 3, max_slots: 3 },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('oas:slot_scheduler_observed')
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

describe('schema drift log aggregation', () => {
  // This suite tests the log-surface throttle only. It does not test that
  // the underlying event is dropped — that is unconditional and is covered
  // by the SSEMessageSchema rejection tests above.
  afterEach(() => {
    vi.useRealTimers()
  })

  it('warns immediately on the first drift of a kind', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    parseSSEMessage({ type: 'still_not_a_real_type' })
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })

  it('suppresses repeats of the same kind within the aggregation window', () => {
    vi.useFakeTimers()
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    for (let i = 0; i < 5; i++) {
      parseSSEMessage({ type: 'flooding_bad_type' })
    }
    // First occurrence logs immediately; the other 4 are counted, not logged.
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })

  it('flushes one aggregated summary line when the window closes, only if repeats occurred', () => {
    vi.useFakeTimers()
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    for (let i = 0; i < 3; i++) {
      parseSSEMessage({ type: 'bursty_bad_type' })
    }
    expect(warnSpy).toHaveBeenCalledOnce()
    vi.advanceTimersByTime(60_000)
    expect(warnSpy).toHaveBeenCalledTimes(2)
    expect(warnSpy.mock.calls[1]![0]).toContain('bursty_bad_type')
    expect(warnSpy.mock.calls[1]![0]).toContain('dropped 3 in 60s')
    warnSpy.mockRestore()
  })

  it('does not emit a second line when a kind never repeats', () => {
    vi.useFakeTimers()
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    parseSSEMessage({ type: 'lonely_bad_type' })
    expect(warnSpy).toHaveBeenCalledOnce()
    vi.advanceTimersByTime(60_000)
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })
})
