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

  it('accepts a typed IDE cursor invalidation', () => {
    const r = SSEMessageSchema.safeParse({
      type: 'ide_cursor_changed',
      keeper_id: 'kidsnote',
    })
    expect(r.success).toBe(true)
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

  it('accepts the null runtime-attempt boundary event', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_RUNTIME_ATTEMPT_STARTED', null),
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

  it('accepts a settled tool approval', () => {
    const r = SSEMessageSchema.safeParse(
      customEvent('KEEPER_TOOL_APPROVAL_SETTLED', {
        tool_call_id: 'tool-use-7',
        outcome: 'approved',
      }),
    )
    expect(r.success).toBe(true)
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
        value: { stop_reason: 'end_turn', usage },
        timestamp: 1_712_000_000,
      },
    })
    // The classic wire shape: the final delta reports only the cumulative
    // output counter. The producer omits unreported fields entirely.
    expect(SSEMessageSchema.safeParse(event({ output_tokens: 42 })).success).toBe(true)
    // The server-tool shape: every counter repeated as a cumulative total —
    // still no total_tokens or cost on a delta.
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
  })

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
      tool_name: 'keeper_time_now',
      composition_tool: 'keeper_compose_mission-snapshot',
      composition_run_id: '019d1234-5678-7abc-8def-0123456789ab',
      composition_node_id: 'clock',
      assembler_run_id: 'exact-assembler-run-42',
      proposal_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      proposal_provenance_status: 'retained_match',
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
      composition_node_id: 'clock',
      assembler_run_id: 'exact-assembler-run-42',
      proposal_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      proposal_provenance_status: 'retained_match',
      parent_tool_use_id: '',
      tool_use_id: 'nested-call',
    })
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('rejects partial or invalid proposal provenance at the websocket boundary', () => {
    const base = {
      type: 'keeper_tool_call_evidence_committed',
      name: 'analyst',
      tool_name: 'keeper_time_now',
      composition_tool: 'keeper_proposal_execute',
      composition_run_id: '019d1234-5678-7abc-8def-0123456789ab',
      composition_node_id: 'clock',
      composition_execution: 'inline',
      parent_tool_use_id: 'outer-call',
      tool_use_id: 'nested-call',
      turn: 7,
      planned_index: 0,
      batch_index: 0,
      batch_size: 1,
      execution_mode: 'serial',
      disposition: 'completed',
      duration_ms: 1,
      ts_unix: 1_786_588_800,
    }
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage({ ...base, proposal_id: 'proposal-only' })).toBeNull()
    expect(parseSSEMessage({
      ...base,
      assembler_run_id: 'run',
      proposal_id: 'proposal',
      proposal_provenance_status: 'guessed',
    })).toBeNull()
    // Both payloads are rejected. Drift logging is rate-limited by event type,
    // so the second malformed event does not emit another warning.
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })

  it('rejects committed composition evidence without exact join identity', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseSSEMessage({
      type: 'keeper_tool_call_evidence_committed',
      name: 'analyst',
      tool_name: 'keeper_time_now',
      composition_tool: 'keeper_compose_mission-snapshot',
      composition_run_id: '',
      composition_node_id: 'clock',
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
