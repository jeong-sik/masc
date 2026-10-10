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
    expect(SSEEventTypeSchema.parse('masc/board_post')).toBe('masc/board_post')
  })

  it('accepts current and future agent-core-prefixed event types', () => {
    expect(SSEEventTypeSchema.parse('agent_core:agent_failed')).toBe('agent_core:agent_failed')
    expect(SSEEventTypeSchema.parse('agent_core:masc:keeper_gate')).toBe('agent_core:masc:keeper_gate')
    expect(SSEEventTypeSchema.parse('agent_core:future:event')).toBe('agent_core:future:event')
  })

  it('accepts audit event wire aliases', () => {
    expect(SSEEventTypeSchema.parse('audit_event')).toBe('audit_event')
    expect(SSEEventTypeSchema.parse('masc:audit_event')).toBe('masc:audit_event')
    expect(SSEEventTypeSchema.parse('agent_core:masc:audit_event')).toBe('agent_core:masc:audit_event')
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

  it('parses an Agent Core event with attribution envelope', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'agent_core:turn_completed',
      correlation_id: 'abc',
      run_id: 'r1',
      attribution: {
        origin: 'det',
        gate: 'agent_core_completion',
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

  it('accepts an operation-keyed Keeper AG-UI event', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ts_unix: 1_712_000_000,
      ag_ui_event: {
        type: 'TEXT_MESSAGE_CONTENT',
        threadId: 'keeper-consumer:sangsu',
        runId: 'run-1',
        messageId: 'message-1',
        delta: '안녕하세요',
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(true)
  })

  it('accepts exact durable tool-result readiness identity', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        runId: 'run-1',
        name: 'KEEPER_TOOL_RESULT_READY',
        value: {
          toolStreamScope: 3,
          toolCallBlockIndex: 7,
          providerMessageId: 'provider-message-1',
          toolCallId: 'tool-use-7',
          executionId: 'exec-7',
        },
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(true)
  })

  it('rejects tool-result readiness without canonical execution identity', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        runId: 'run-1',
        name: 'KEEPER_TOOL_RESULT_READY',
        value: { toolStreamScope: 3, toolCallBlockIndex: 7 },
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(false)
  })

  const exactToolOccurrence = {
    toolStreamScope: 3,
    toolCallBlockIndex: 7,
  }

  const toolOperationEvent = (agUiEvent: Record<string, unknown>) => ({
    type: 'keeper_chat_operation_event',
    name: 'sangsu',
    operation_id: 'kmsg-operation-1',
    ag_ui_event: {
      threadId: 'keeper-consumer:sangsu',
      timestamp: 1_712_000_000,
      ...agUiEvent,
    },
  })

  it.each([
    {
      label: 'start',
      event: { type: 'TOOL_CALL_START', ...exactToolOccurrence, toolCallName: 'Read' },
    },
    {
      label: 'args',
      event: { type: 'TOOL_CALL_ARGS', ...exactToolOccurrence, delta: '{}' },
    },
    {
      label: 'end',
      event: { type: 'TOOL_CALL_END', ...exactToolOccurrence },
    },
    {
      label: 'result',
      event: {
        type: 'CUSTOM',
        name: 'KEEPER_TOOL_RESULT_READY',
        value: { ...exactToolOccurrence, executionId: 'exec-7' },
      },
    },
  ])('accepts providerless $label with an exact stream occurrence', ({ event }) => {
    expect(SSEMessageSchema.safeParse(toolOperationEvent(event)).success).toBe(true)
  })

  it.each([
    { type: 'TOOL_CALL_START', toolCallName: 'Read' },
    { type: 'TOOL_CALL_ARGS', delta: '{}' },
    { type: 'TOOL_CALL_END' },
    {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { executionId: 'exec-7' },
    },
  ])('rejects a tool event without its exact stream occurrence: %o', event => {
    expect(SSEMessageSchema.safeParse(toolOperationEvent(event)).success).toBe(false)
  })

  it.each([
    {
      type: 'TOOL_CALL_START',
      ...exactToolOccurrence,
      toolStreamScope: -1,
      toolCallName: 'Read',
    },
    {
      type: 'TOOL_CALL_END',
      ...exactToolOccurrence,
      toolCallBlockIndex: 1.5,
    },
    {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...exactToolOccurrence, toolCallBlockIndex: -1, executionId: 'exec-7' },
    },
  ])('rejects a malformed tool stream occurrence: %o', event => {
    expect(SSEMessageSchema.safeParse(toolOperationEvent(event)).success).toBe(false)
  })

  it.each([
    {
      type: 'TOOL_CALL_ARGS',
      ...exactToolOccurrence,
      providerMessageId: ' ',
      delta: '{}',
    },
    {
      type: 'TOOL_CALL_END',
      ...exactToolOccurrence,
      toolCallId: '',
    },
    {
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: { ...exactToolOccurrence, providerMessageId: '', executionId: 'exec-7' },
    },
  ])('rejects a blank optional tool correlation field: %o', event => {
    expect(SSEMessageSchema.safeParse(toolOperationEvent(event)).success).toBe(false)
  })

  it('rejects legacy snake_case result identity fields', () => {
    expect(SSEMessageSchema.safeParse(toolOperationEvent({
      type: 'CUSTOM',
      name: 'KEEPER_TOOL_RESULT_READY',
      value: {
        tool_stream_scope: 3,
        tool_call_block_index: 7,
        tool_call_id: 'tool-use-7',
        execution_id: 'exec-7',
      },
    })).success).toBe(false)
  })

  // The three below reached main with a name in the contract and no field list.
  // The lookup fell back to an empty list, so every field the server actually
  // sends read as an unexpected one and the whole turn failed. Each case here
  // carries the exact payload lib/server/server_keeper_chat_agui_projection.ml
  // and server_routes_http_keeper_stream.ml emit.
  const customEvent = (name: string, value: unknown) => ({
    type: 'keeper_chat_operation_event',
    name: 'sangsu',
    operation_id: 'kmsg-operation-1',
    ag_ui_event: {
      type: 'CUSTOM',
      threadId: 'keeper-consumer:sangsu',
      runId: 'run-1',
      name,
      value,
      timestamp: 1_712_000_000,
    },
  })

  it.each([
    ['text', 'observed'], ['thinking', 'observed'], ['text', 'ended'], ['thinking', 'ended'],
  ])('accepts exact %s content %s metadata with or without provider correlation', (channel, state) => {
    const activity = { generation: 17, stream_scope: 0, block_index: 2, channel, state }
    for (const value of [activity, { ...activity, provider_message_id: 'reused-id' }]) {
      const event = customEvent('KEEPER_MODEL_CONTENT_ACTIVITY', value)
      const result = SSEMessageSchema.safeParse(event)
      expect(result.success).toBe(true)
      if (result.success) expect(result.data.ag_ui_event).toEqual(event.ag_ui_event)
    }
  })

  it('rejects malformed model activity without weakening the shared payload contract', () => {
    const valid = { generation: 17, stream_scope: 0, block_index: 2, channel: 'text', state: 'observed' }
    const malformed: unknown[] = [
      null, [], 'observed',
      { ...valid, generation: -1 }, { ...valid, stream_scope: -1 }, { ...valid, block_index: -1 },
      { ...valid, generation: 1.5 }, { ...valid, stream_scope: '0' }, { ...valid, block_index: null },
      { ...valid, generation: Number.MAX_SAFE_INTEGER + 1 },
      { ...valid, generation: undefined }, { ...valid, stream_scope: undefined },
      { ...valid, block_index: undefined },
      { ...valid, channel: 'tool' }, { ...valid, state: 'success' },
      { ...valid, channel: undefined }, { ...valid, state: undefined },
      { ...valid, provider_message_id: '' }, { ...valid, provider_message_id: '  ' },
      { ...valid, provider_message_id: null }, { ...valid, provider_message_id: 4 },
      { ...valid, provider_message_id: undefined }, { ...valid, delta: 'not body text' },
    ]
    for (const value of malformed) {
      expect(SSEMessageSchema.safeParse(customEvent('KEEPER_MODEL_CONTENT_ACTIVITY', value)).success).toBe(false)
    }
    for (const field of ['generation', 'stream_scope', 'block_index', 'channel', 'state']) {
      const value = Object.fromEntries(Object.entries(valid).filter(([key]) => key !== field))
      expect(SSEMessageSchema.safeParse(customEvent('KEEPER_MODEL_CONTENT_ACTIVITY', value)).success).toBe(false)
    }
  })

  it('accepts native starts with exact occurrence and optional provider identity', () => {
    for (const value of [
      { toolStreamScope: 0, toolCallBlockIndex: 0 },
      { toolStreamScope: 2, toolCallBlockIndex: 7, providerMessageId: 'reused', toolCallId: 'native', toolCallName: 'Read' },
    ]) {
      const event = customEvent('KEEPER_NATIVE_TOOL_START', value)
      const parsed = parseSSEMessage(event)
      expect(parsed?.ag_ui_event).toEqual(event.ag_ui_event)
    }
  })

  it.each([
    { kind: 'end_observed', exit_code: null },
    { kind: 'completion_reported', exit_code: null },
    { kind: 'completion_reported', exit_code: 0 },
    { kind: 'completion_reported', exit_code: 17 },
    { kind: 'error_reported', exit_code: -15 },
    { kind: 'decline_reported', exit_code: null },
    { kind: 'result_received', exit_code: null, is_error: null },
    { kind: 'result_received', exit_code: null, is_error: false },
    { kind: 'result_received', exit_code: 3, is_error: true },
    { kind: 'unrecognized_status', exit_code: null, status: 'future-provider-status' },
    { kind: 'unrecognized_status', exit_code: null, status: '' },
  ])('preserves native completion facts without a success inference: %j', completion => {
    const event = customEvent('KEEPER_NATIVE_TOOL_END', {
      toolStreamScope: 2, toolCallBlockIndex: 7, completion,
    })
    const parsed = parseSSEMessage(event)
    expect(parsed?.ag_ui_event).toEqual(event.ag_ui_event)
  })

  it('accepts an older native end without inventing completion metadata', () => {
    const event = customEvent('KEEPER_NATIVE_TOOL_END', { toolStreamScope: 0, toolCallBlockIndex: 0 })
    const parsed = parseSSEMessage(event)
    expect(parsed?.ag_ui_event).toEqual(event.ag_ui_event)
  })

  it.each([
    { kind: 'output_observed', byte_count: 1 },
    { kind: 'output_observed', byte_count: 4096 },
    { kind: 'heartbeat_reported', elapsed_seconds: 0 },
    { kind: 'heartbeat_reported', elapsed_seconds: 30 },
    { kind: 'heartbeat_reported', elapsed_seconds: 3 },
    { kind: 'message_reported', message: '' },
    { kind: 'message_reported', message: 'provider progress \n다음' },
  ])('accepts and retains typed native progress: %j', progress => {
    const event = customEvent('KEEPER_NATIVE_TOOL_PROGRESS', {
      toolStreamScope: 2, toolCallBlockIndex: 7, toolCallName: 'Read', progress,
    })
    expect(parseSSEMessage(event)?.ag_ui_event).toEqual(event.ag_ui_event)
  })

  it('rejects malformed or contradictory native completion objects', () => {
    for (const completion of [
      null, [], 'completed', {},
      { kind: 'success', exit_code: 0 },
      { kind: 'end_observed' },
      { kind: 'completion_reported', exit_code: '0' },
      { kind: 'completion_reported', exit_code: 0.5 },
      { kind: 'completion_reported', exit_code: Number.MAX_SAFE_INTEGER + 1 },
      { kind: 'completion_reported', exit_code: Infinity },
      { kind: 'completion_reported', exit_code: 0, is_error: false },
      { kind: 'error_reported', exit_code: 0, status: 'failed' },
      { kind: 'result_received', exit_code: null },
      { kind: 'result_received', exit_code: null, is_error: 'false' },
      { kind: 'result_received', exit_code: null, is_error: false, status: 'completed' },
      { kind: 'unrecognized_status', exit_code: null },
      { kind: 'unrecognized_status', exit_code: null, status: false },
      { kind: 'unrecognized_status', exit_code: null, status: 'future', is_error: true },
      { kind: 'end_observed', exit_code: null, extra: true },
    ]) {
      expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_END', {
        toolStreamScope: 0, toolCallBlockIndex: 0, completion,
      })).success).toBe(false)
    }
  })

  it('rejects missing, malformed, and cross-variant native progress', () => {
    for (const progress of [
      undefined, null, [], {},
      { kind: 'output_observed', byte_count: 0 },
      { kind: 'output_observed', byte_count: -1 },
      { kind: 'output_observed', byte_count: 1.5 },
      { kind: 'output_observed', byte_count: '1' },
      { kind: 'output_observed', byte_count: Number.MAX_SAFE_INTEGER + 1 },
      { kind: 'output_observed', byte_count: 1, message: 'not output bytes' },
      { kind: 'message_reported' },
      { kind: 'message_reported', message: null },
      { kind: 'message_reported', message: 'ok', byte_count: 1 },
      { kind: 'message_reported', message: '', extra: true },
      { kind: 'heartbeat', elapsed_seconds: 1 },
      { kind: 'heartbeat_reported' },
      { kind: 'heartbeat_reported', elapsed_seconds: null },
      { kind: 'heartbeat_reported', elapsed_seconds: -1 },
      { kind: 'heartbeat_reported', elapsed_seconds: 0.5 },
      { kind: 'heartbeat_reported', elapsed_seconds: '30' },
      { kind: 'heartbeat_reported', elapsed_seconds: Infinity },
      { kind: 'heartbeat_reported', elapsed_seconds: Number.MAX_SAFE_INTEGER + 1 },
      { kind: 'heartbeat_reported', elapsed_seconds: 30, byte_count: 1 },
      { kind: 'heartbeat_reported', elapsed_seconds: 30, message: 'wrong variant' },
    ]) {
      expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_PROGRESS', {
        toolStreamScope: 0, toolCallBlockIndex: 0, progress,
      })).success).toBe(false)
    }
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_PROGRESS', {
      toolStreamScope: 0, toolCallBlockIndex: 0,
    })).success).toBe(false)
  })

  it('rejects malformed occurrence and event-incompatible native fields', () => {
    const occurrence = { toolStreamScope: 0, toolCallBlockIndex: 0 }
    for (const value of [
      {}, { ...occurrence, toolStreamScope: -1 }, { ...occurrence, toolCallBlockIndex: '0' },
      { ...occurrence, toolCallBlockIndex: 0.5 }, { ...occurrence, providerMessageId: null },
      { ...occurrence, toolCallId: '' }, { ...occurrence, toolCallName: ' ' },
      { ...occurrence, toolCallName: 1 }, { ...occurrence, toolCallName: undefined },
      { ...occurrence, executionId: 'invented-receipt' },
      { ...occurrence, completion: { kind: 'end_observed', exit_code: null } },
      { ...occurrence, progress: { kind: 'output_observed', byte_count: 1 } },
    ]) {
      expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_START', value)).success).toBe(false)
    }
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_END', {
      ...occurrence, progress: { kind: 'output_observed', byte_count: 1 },
    })).success).toBe(false)
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_NATIVE_TOOL_PROGRESS', {
      ...occurrence, progress: { kind: 'message_reported', message: '' },
      completion: { kind: 'end_observed', exit_code: null },
    })).success).toBe(false)
    const malformed = parseSSEMessage(customEvent('KEEPER_NATIVE_TOOL_END', {
      ...occurrence, completion: null,
    }))
    expect(malformed?.ag_ui_event).toEqual(expect.objectContaining({ type: 'RUN_ERROR', code: 'invalid_event_payload' }))
  })

  it('accepts the null runtime-attempt boundary event', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_RUNTIME_ATTEMPT_STARTED', null),
    )
    expect(r.success).toBe(true)
  })

  it('accepts the runtime-attempt boundary event with runtime_id and attempt_index', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_RUNTIME_ATTEMPT_STARTED', {
        runtime_id: 'claude-3-7-sonnet',
        attempt_index: 1,
      }),
    )
    expect(r.success).toBe(true)
  })

  it('accepts an exact quarantined occurrence on a stream protocol error', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_STREAM_PROTOCOL_ERROR', {
        kind: 'tool_args_without_start',
        reason: 'quarantined exact occurrence',
        quarantined_occurrence: {
          toolStreamScope: 3,
          toolCallBlockIndex: 7,
          providerMessageId: 'provider-message-1',
        },
      }),
    )
    expect(r.success).toBe(true)
  })

  it.each([
    'tool_delta_invalid_kind',
    'tool_attempt_superseded',
    'tool_message_start_conflict',
    'stream_event_after_terminal',
  ])(
    'accepts the %s typed quarantine kind',
    kind => {
      const r = SSEMessageSchema.safeParse(
        customEvent('KEEPER_STREAM_PROTOCOL_ERROR', {
          kind,
          reason: 'exact occurrence terminalized',
          quarantined_occurrence: exactToolOccurrence,
        }),
      )
      expect(r.success).toBe(true)
    },
  )

  it.each([
    { toolCallBlockIndex: 7 },
    { toolStreamScope: 3, toolCallBlockIndex: -1 },
    { toolStreamScope: 3, toolCallBlockIndex: 7, providerMessageId: ' ' },
    { toolStreamScope: 3, toolCallBlockIndex: 7, toolCallId: 'not-allowed' },
  ])('rejects a malformed quarantined occurrence: %o', quarantinedOccurrence => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_STREAM_PROTOCOL_ERROR', {
        kind: 'tool_args_without_start',
        quarantined_occurrence: quarantinedOccurrence,
      }),
    )
    expect(r.success).toBe(false)
  })

  // Attempt failures carry no quarantined occurrence: the attempt ended and
  // the next one follows in the same bubble, so the frame must decode.
  it.each(['sse_timeout', 'sse_stream_repeating'])(
    'accepts the %s attempt-failure kind without a quarantined occurrence',
    kind => {
      const r = SSEMessageSchema.safeParse(
        customEvent('KEEPER_STREAM_PROTOCOL_ERROR', {
          kind,
          reason: 'the attempt ended; the next one follows',
        }),
      )
      expect(r.success).toBe(true)
    },
  )

  it('rejects a stream protocol error kind outside the contract list', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_STREAM_PROTOCOL_ERROR', {
        kind: 'sse_not_a_kind',
        reason: 'never emitted by the backend',
      }),
    )
    expect(r.success).toBe(false)
  })

  it('accepts a tool approval request with the fields the server sends', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_REQUESTED', {
        tool_call_id: 'tool-use-7',
        tool_call_name: 'execute',
        args: '{"command":"ls"}',
        question: 'Run this command?',
        because: 'process execution requires approval',
      }),
    )
    expect(r.success).toBe(true)
  })

  it('accepts an older tool approval request without because', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_REQUESTED', {
        tool_call_id: 'tool-use-old',
        tool_call_name: 'execute',
        args: '{}',
        question: 'Run this command?',
      }),
    )
    expect(r.success).toBe(true)
  })

  it('rejects a non-string tool approval reason', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_REQUESTED', {
        tool_call_id: 'tool-use-7',
        tool_call_name: 'execute',
        args: '{}',
        question: 'Run this command?',
        because: 42,
      }),
    )
    expect(r.success).toBe(false)
  })

  // terminal_stream_scope rides KEEPER_REPLY_DETAILS as an optional field the
  // server omits entirely when None (json_opt -> []). lib/keeper/
  // keeper_chat_event_log.ml optional_stream_scope accepts absence and a
  // nonnegative integer and rejects everything else, including null.
  const replyDetails = (value: Record<string, unknown>) =>
    customEvent('KEEPER_REPLY_DETAILS', value)

  const validReplyDetails = {
    reply: 'Done.',
    turn_outcome: 'visible_reply',
    turn_ref: 'turn-7',
  }

  it('accepts a reply details event with a terminal stream scope', () => {
    expect(
      SSEMessageSchema.safeParse(
        replyDetails({ ...validReplyDetails, terminal_stream_scope: 2 }),
      ).success,
    ).toBe(true)
  })

  it('accepts reply details without the terminal stream scope key', () => {
    expect(SSEMessageSchema.safeParse(replyDetails(validReplyDetails)).success).toBe(true)
  })

  it.each([0, 1, 3, 7])('accepts a nonnegative terminal stream scope: %s', scope => {
    expect(
      SSEMessageSchema.safeParse(replyDetails({ ...validReplyDetails, terminal_stream_scope: scope }))
        .success,
    ).toBe(true)
  })

  it.each([-1, '1', null, 1.5, Number.MAX_SAFE_INTEGER + 1])(
    'rejects a malformed terminal stream scope: %s',
    scope => {
      expect(
        SSEMessageSchema.safeParse(
          replyDetails({ ...validReplyDetails, terminal_stream_scope: scope }),
        ).success,
      ).toBe(false)
    },
  )

  it('accepts a settled tool approval', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_SETTLED', {
        tool_call_id: 'tool-use-7',
        outcome: 'approved',
      }),
    )
    expect(r.success).toBe(true)
  })

  it('accepts a shared execution binding and rejects unknown fields', () => {
    const binding = { operation_id: 'member-1', execution_id: 'leader-1' }
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_CHAT_BATCH_BOUND', binding)).success).toBe(true)
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_CHAT_BATCH_BOUND', { ...binding, guessed: true })).success).toBe(false)
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_CHAT_BATCH_BOUND', { operation_id: 'member-1' })).success).toBe(false)
  })

  it('retains interactive acceptance facts without inventing effects', () => {
    const accepted = { operation_id: 'member-1', state: 'Queued', queued_count: 2 }
    const interactive = { outcome: 'stale_control', chat_control_token: 'fresh-control', signalled: false, resumed: false, interrupt_error: null }
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_CHAT_OPERATION_ACCEPTED', { ...accepted, interactive })).success).toBe(true)
    expect(SSEMessageSchema.safeParse(customEvent('KEEPER_CHAT_OPERATION_ACCEPTED', { ...accepted, interactive: { ...interactive, resumed: true } })).success).toBe(false)
  })

  it('accepts a durable chat operation acceptance', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_CHAT_OPERATION_ACCEPTED', {
        operation_id: 'kmsg-operation-1',
        state: 'Running',
        queued_count: 2,
      }),
    )
    expect(r.success).toBe(true)
  })

  it('still rejects a field the approval contract does not carry', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_REQUESTED', {
        tool_call_id: 'tool-use-7',
        tool_call_name: 'execute',
        args: '{}',
        question: 'Run this command?',
        deadline_ms: 30_000,
      }),
    )
    expect(r.success).toBe(false)
  })

  it('accepts a message_delta usage that reports only some cumulative counters', () => {
    const event = (usage: unknown) => ({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        runId: 'run-1',
        name: 'KEEPER_STREAM_MESSAGE_DELTA',
        value: { stream_scope: 4, stop_reason: 'end_turn', usage },
        timestamp: 1_712_000_000,
      },
    })
    // The classic wire shape: the final delta reports only the cumulative
    // output counter. The producer omits unreported fields entirely.
    expect(SSEMessageSchema.safeParse(event({ output_tokens: 42 })).success).toBe(true)
    // The server-tool shape: every counter repeated as a cumulative total —
    // still no total_tokens on a delta.
    expect(
      SSEMessageSchema.safeParse(
        event({
          input_tokens: 60_882,
          output_tokens: 510,
          cache_creation_input_tokens: 200,
          cache_read_input_tokens: 50_000,
        }),
      ).success,
    ).toBe(true)
    expect(SSEMessageSchema.safeParse(event({ output_tokens: 4.2 })).success).toBe(false)
    expect(SSEMessageSchema.safeParse(event({ total_tokens: 9 })).success).toBe(false)
    for (const cost_usd of [0, 0.0123]) {
      const parsed = SSEMessageSchema.safeParse(event({ output_tokens: 42, cost_usd }))
      expect(parsed.success).toBe(true)
      if (parsed.success) expect(parsed.data).toEqual(event({ output_tokens: 42, cost_usd }))
      expect(SSEMessageSchema.safeParse(event({ cost_usd })).success).toBe(true)
    }
    for (const cost_usd of [null, '0.0123', -0.0123, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(SSEMessageSchema.safeParse(event({ cost_usd })).success).toBe(false)
    }
  })

  it.each(['KEEPER_STREAM_MESSAGE_START', 'KEEPER_STREAM_MESSAGE_DELTA'])(
    'retains a response identity on %s frames and rejects invalid identities', name => {
      const event = (stream_scope: unknown) => ({
        type: 'keeper_chat_operation_event',
        name: 'sangsu',
        operation_id: 'kmsg-operation-1',
        ag_ui_event: {
          type: 'CUSTOM',
          threadId: 'keeper-consumer:sangsu',
          runId: 'run-1',
          name,
          value: name === 'KEEPER_STREAM_MESSAGE_START'
            ? { stream_scope, provider_message_id: 'pm-1', model: 'observed-model' }
            : { stream_scope, stop_reason: 'end_turn' },
          timestamp: 1_712_000_000,
        },
      })
      for (const scope of [0, 4]) {
        const result = SSEMessageSchema.safeParse(event(scope))
        expect(result.success).toBe(true)
        if (result.success) {
          expect(result.data).toMatchObject({ ag_ui_event: { value: { stream_scope: scope } } })
        }
      }
      for (const scope of [undefined, null, -1, 0.5, '4']) {
        expect(SSEMessageSchema.safeParse(event(scope)).success).toBe(false)
      }
    },
  )

  it('accepts an operator-visible projection error for an operation', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'RUN_ERROR',
        threadId: 'keeper-consumer:sangsu',
        message: 'Unsupported Keeper chat event: KEEPER_UNTYPED_EVENT',
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(true)
  })

  it('accepts external-effect completion only with a typed delivery target', () => {
    const event = (value: unknown) => ({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        name: 'KEEPER_EXTERNAL_EFFECT_COMPLETED',
        value,
        timestamp: 1_712_000_000,
      },
    })
    expect(SSEMessageSchema.safeParse(event(null)).success).toBe(false)
    expect(SSEMessageSchema.safeParse(event({})).success).toBe(false)
    expect(
      SSEMessageSchema.safeParse(event({ target: { kind: 'dashboard' } })).success,
    ).toBe(true)
    expect(
      SSEMessageSchema.safeParse(
        event({
          target: {
            kind: 'slack',
            channel_id: 'C09TK9L4DV4',
            thread_ts: '1786524720.554309',
          },
        }),
      ).success,
    ).toBe(true)
    expect(
      SSEMessageSchema.safeParse(event({ target: { kind: 'telegram' } })).success,
    ).toBe(false)
    expect(
      SSEMessageSchema.safeParse(event({ target: { kind: 'slack' } })).success,
    ).toBe(false)
    expect(
      SSEMessageSchema.safeParse(event({ widened: true })).success,
    ).toBe(false)
  })

  it('rejects an untyped Keeper custom event name', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'CUSTOM',
        threadId: 'keeper-consumer:sangsu',
        name: 'KEEPER_UNTYPED_EVENT',
        value: null,
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(false)
  })

  it('rejects fields outside the exact AG-UI event variant', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: 'kmsg-operation-1',
      ag_ui_event: {
        type: 'TEXT_MESSAGE_CONTENT',
        threadId: 'keeper-consumer:sangsu',
        delta: 'hello',
        toolCallId: 'not-valid-for-text',
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(false)
  })

  it('rejects the removed Keeper turn event contract', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_chat_turn_event',
      name: 'sangsu',
      ag_ui_event: {
        type: 'RUN_STARTED',
        threadId: 'keeper-consumer:sangsu',
        timestamp: 1_712_000_000,
      },
    })
    expect(r.success).toBe(false)
  })

  it('accepts a typed Keeper waiting-inventory invalidation', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'keeper_waiting_inventory_changed',
      keeper_name: 'keeper-1',
      queue_kind: 'chat_operation',
      ts_unix: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it('accepts the exact runtime telemetry sample envelope', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'agent_core_telemetry_sample',
      payload: {
        sample: { provider_id: 'private', model_id: 'private', status: 'ok' },
        recorded_at: 1_712_000_000,
      },
      provider_id: 'runtime',
      model_id: 'runtime',
      ts_unix: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it.each([
    { payload: { sample: {}, recorded_at: 1 }, provider_id: 'runtime' },
    { payload: { sample: {}, recorded_at: 'bad' }, provider_id: 'runtime', model_id: 'runtime' },
    { payload: { recorded_at: 1 }, provider_id: 'runtime', model_id: 'runtime' },
  ])('rejects malformed runtime telemetry sample envelopes: %o', value => {
    expect(SSEMessageSchema.safeParse({ type: 'agent_core_telemetry_sample', ...value }).success).toBe(false)
  })

  it.each([
    { type: 'keeper_waiting_inventory_changed', queue_kind: 'chat_operation' },
    { type: 'keeper_waiting_inventory_changed', keeper_name: 'keeper-1' },
    { type: 'keeper_waiting_inventory_changed', keeper_name: 'keeper-1', queue_kind: 'unknown' },
  ])('rejects an incomplete Keeper waiting-inventory invalidation: %o', value => {
    expect(SSEMessageSchema.safeParse(value).success).toBe(false)
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

  it('accepts a masc/task_claimed event', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'masc/task_claimed',
      task_id: 'task-1',
      agent_name: 'claude',
      timestamp: 1_712_000_000,
    })
    expect(r.success).toBe(true)
  })

  it.each([
    { type: 'masc/task_claimed', agent_name: 'claude' },
    { type: 'masc/task_claimed', task_id: 'task-1' },
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

  it('keeps internal agent invalidations at the websocket parse boundary', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({ type: 'internal_agent_runs_changed' })
    expect(msg?.type).toBe('internal_agent_runs_changed')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('keeps committed composition evidence at the websocket parse boundary', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'keeper_tool_call_evidence_committed',
      name: 'analyst',
      tool_name: 'keeper_lane_status',
      composition_tool: 'keeper_compose_work-intake',
      composition_run_id: '019d1234-5678-7abc-8def-0123456789ab',
      composition_node_id: 'lane',
      composition_execution: 'inline',
      parent_tool_use_id: '',
      tool_use_id: 'nested-call',
      turn: 7,
      planned_index: 0,
      batch_index: 0,
      batch_size: 3,
      execution_mode: 'concurrent',
      success: true,
      disposition: 'completed',
      duration_ms: 12.5,
      ts_unix: 1_786_588_800,
    })

    expect(msg).toMatchObject({
      type: 'keeper_tool_call_evidence_committed',
      name: 'analyst',
      composition_node_id: 'lane',
      parent_tool_use_id: '',
      tool_use_id: 'nested-call',
    })
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('rejects committed composition evidence without exact join identity', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage({
      type: 'keeper_tool_call_evidence_committed',
      name: 'analyst',
      tool_name: 'keeper_lane_status',
      composition_tool: 'keeper_compose_work-intake',
      composition_run_id: '',
      composition_node_id: 'lane',
      composition_execution: 'inline',
      parent_tool_use_id: 'outer-call',
      tool_use_id: 'nested-call',
      turn: 7,
      planned_index: 0,
      batch_index: 0,
      batch_size: 3,
      execution_mode: 'concurrent',
      success: true,
      disposition: 'completed',
      duration_ms: 12.5,
      ts_unix: 1_786_588_800,
    })).toBeNull()
    expect(warnSpy).toHaveBeenCalledOnce()
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

  it('keeps unknown agent-core-prefixed events instead of dropping them', () => {
    const msg = parseSSEMessage({
      type: 'agent_core:slot_scheduler_observed',
      payload: { state: 'saturated', active: 3, max_slots: 3 },
    })
    expect(msg).not.toBeNull()
    expect(msg?.type).toBe('agent_core:slot_scheduler_observed')
  })

  it('keeps agentCore telemetry tuple payloads instead of logging schema drift', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const msg = parseSSEMessage({
      type: 'agent_core:telemetry_event',
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
    expect(msg?.type).toBe('agent_core:telemetry_event')
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
