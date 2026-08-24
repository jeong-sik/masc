// Lightweight schema-at-boundary for SSE events from the MCP server.
//
// This module intentionally avoids pulling a generic schema runtime into the
// dashboard hot path. SSE and WebSocket push streams import this parser during
// boot, so keep validation direct and limited to the boundary guarantees the
// handlers rely on.

import type {
  Attribution,
  AttributionOutcome,
  SSEAudioClip,
  SSEEvent,
  SSEEventType,
} from '../types/sse'
import { KEEPER_CHAT_CUSTOM_EVENT_NAMES } from '../lib/keeper-chat-stream-contract'
import type { KeeperChatCustomEventName } from '../lib/keeper-chat-stream-contract'
import { isRecord } from '../lib/type-guards'
import { isAgentCoreEventType } from '../lib/sse-event-type'

type SchemaIssue = { path?: string; message: string }
type SafeParseSuccess<T> = { success: true; data: T }
type SafeParseFailure = { success: false; error: { issues: SchemaIssue[] } }
type SafeParseResult<T> = SafeParseSuccess<T> | SafeParseFailure

type SchemaLike<T> = {
  parse(value: unknown): T
  safeParse(value: unknown): SafeParseResult<T>
}

export const SSE_APPROVAL_PENDING_EVENT = 'approval:pending'
export const SSE_APPROVAL_RESOLVED_EVENT = 'approval:resolved'
export const SSE_APPROVAL_AUDIT_EVENT = 'approval:audit'
export const SSE_APPROVAL_SUMMARY_UPDATED_EVENT = 'approval:summary_updated'

// Dead entries are removed, not kept for compatibility: an allowlist row whose
// OCaml producer no longer exists only hides real drops (#28925 audit, defect
// (c)). Removed 2026-08-17 with their producers' removal receipts:
//   agent_bound/agent_unbound (+masc/) — producer (agent_joined era) deleted in
//     #2149; TS waiters were renamed onto the dead event in #19668.
//   task_update — producer deleted in #3497 (dead-module purge).
//   keeper_guardrail (+masc/) — SSE emit deleted in #1815 (legacy loop removal).
//   keeper_tool_skipped — SSE emit deleted in #24332 (governance→Gate).
//   client_input_approved/rejected/updated — TRPG game_view producer archived
//     out of lib/ in #1668.
const FIXED_SSE_EVENT_TYPES = new Set([
  'broadcast',
  'masc/broadcast',
  'workspace_message_delivery_changed',
  'board_post',
  'masc/board_post',
  'board_comment',
  'masc/board_comment',
  'board_delete',
  'masc/board_delete',
  'post_created',
  'comment_added',
  'post_voted',
  'comment_voted',
  'reaction_changed',
  'heartbeat',
  'keeper_heartbeat',
  'keeper_handoff',
  'masc/keeper_handoff',
  'keeper_compaction',
  'masc/keeper_compaction',
  'keeper_phase_changed',
  'keeper_composite_changed',
  'keeper_chat_appended',
  'keeper_chat_operation_event',
  'keeper_waiting_inventory_changed',
  'agent_core_telemetry_sample',
  'ide_cursor_changed',
  'keeper_tool_call',
  'masc/keeper_tool_call',
  'keeper_tool_call_evidence_committed',
  'keeper_turn_complete',
  'masc/keeper_turn_complete',
  // RFC-0266 Phase 4: fusion run-status transitions (running -> completed/failed).
  // Must be in this closed allowlist or parseSSEMessage drops the event at the
  // parse boundary, before the live WS router (sse-store.ts routeServerPushEvent
  // -> SIMPLE_ROUTES['fusion_run_status'] -> refreshFusionRuns) can dispatch it.
  'fusion_run_status',
  'internal_agent_runs_changed',
  'runtime_param_changed',
  SSE_APPROVAL_PENDING_EVENT,
  SSE_APPROVAL_RESOLVED_EVENT,
  SSE_APPROVAL_AUDIT_EVENT,
  SSE_APPROVAL_SUMMARY_UPDATED_EVENT,
  // Nonhierarchical Gate mode transitions (#24332 governance->gate refactor).
  // Emitted by server_routes_http_routes_dashboard.ml.
  'gate_mode_changed',
  // Task claim notifications (#18839). Emitted by
  // lib/task/tool_task_handlers.ml. Routed by the 'masc/task_' PREFIX_ROUTES
  // entry in sse-store.ts.
  'masc/task_claimed',
  'project_snapshot',
  'execution_snapshot',
  'operator_snapshot',
  'operator_digest',
  'transport_health_snapshot',
  'masc:audit_event',
  'audit_event',
  'masc/audit_event',
])

const STRING_FIELDS = new Set([
  'severity',
  'source',
  'connector',
  'agent',
  'from',
  'from_agent',
  'message',
  'content',
  'task_id',
  'status',
  'post_id',
  'comment_id',
  'post_kind',
  'title',
  'author',
  'voter',
  'direction',
  'target_type',
  'target_id',
  'user_id',
  'emoji',
  'hearth',
  'agent_name',
  'keeper_name',
  'keeper_id',
  'event_type',
  'name',
  'from_model',
  'to_model',
  'trigger',
  'reason',
  'prev_phase',
  'new_phase',
  'event',
  'tool_name',
  'disposition',
  'error_text',
  'tool_args_preview',
  'tool_output_preview',
  'composition_tool',
  'composition_run_id',
  'composition_node_id',
  'composition_execution',
  'parent_tool_use_id',
  'tool_use_id',
  'execution_mode',
  'reason_code',
  'phase',
  'from_state',
  'to_state',
  'session_id',
  'operation_id',
  'worker_run_id',
  'model_used',
  'correlation_id',
  'run_id',
  // gate_mode_changed
  'mode',
  'previous_mode',
  'actor',
  'changed_at',
  'kind',
  'provider_id',
  'model_id',
])

const NUMBER_FIELDS = new Set([
  'generation',
  'context_ratio',
  'ts_unix',
  'from_generation',
  'to_generation',
  'before_tokens',
  'after_tokens',
  'saved_tokens',
  'revision',
  'duration_ms',
  'turn',
  'planned_index',
  'batch_index',
  'batch_size',
  'input_tokens',
  'output_tokens',
  'cost_usd',
  'tool_calls_made',
  'total_turns',
  // masc/task_claimed
  'timestamp',
])

const BOOLEAN_FIELDS = new Set(['success', 'reacted', 'tool_io_redacted'])

const KEEPER_CHAT_AG_UI_EVENT_TYPES = new Set([
  'RUN_STARTED',
  'RUN_FINISHED',
  'RUN_ERROR',
  'TEXT_MESSAGE_START',
  'TEXT_MESSAGE_CONTENT',
  'TEXT_MESSAGE_END',
  'TOOL_CALL_START',
  'TOOL_CALL_ARGS',
  'TOOL_CALL_END',
  'CUSTOM',
])

const KEEPER_CHAT_CUSTOM_EVENT_NAME_SET: ReadonlySet<string> = new Set(
  KEEPER_CHAT_CUSTOM_EVENT_NAMES,
)

function isKeeperCustomEventName(name: string): name is KeeperChatCustomEventName {
  return KEEPER_CHAT_CUSTOM_EVENT_NAME_SET.has(name)
}
const KEEPER_CHAT_AG_UI_BASE_FIELDS = ['type', 'threadId', 'timestamp'] as const
const KEEPER_CHAT_AG_UI_FIELDS_BY_TYPE = new Map<string, ReadonlySet<string>>([
  ['RUN_STARTED', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId'])],
  ['RUN_FINISHED', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId'])],
  ['RUN_ERROR', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'message', 'code'])],
  ['TEXT_MESSAGE_START', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'messageId', 'role'])],
  ['TEXT_MESSAGE_CONTENT', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'messageId', 'delta'])],
  ['TEXT_MESSAGE_END', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'messageId'])],
  ['TOOL_CALL_START', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'toolCallId', 'toolCallName'])],
  ['TOOL_CALL_ARGS', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'toolCallId', 'delta', 'snapshot'])],
  ['TOOL_CALL_END', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'toolCallId'])],
  ['CUSTOM', new Set([...KEEPER_CHAT_AG_UI_BASE_FIELDS, 'runId', 'name', 'value'])],
])

function ok<T>(data: T): SafeParseSuccess<T> {
  return { success: true, data }
}

function fail<T = never>(path: string | undefined, message: string): SafeParseResult<T> {
  return { success: false, error: { issues: [{ path, message }] } }
}

const KEEPER_STREAM_PROTOCOL_ERROR_KINDS = new Set([
  'tool_start_duplicate_index',
  'tool_start_missing_identity',
  'tool_args_without_start',
  'tool_stop_without_start',
  'media_delta_invalid_block',
  'media_source_unsupported',
  'media_decode_failed',
  'media_payload_too_large',
  'media_persist_failed',
  'sse_error',
  'ndjson_error',
  'sse_parse_failed',
  'ndjson_parse_failed',
  'sse_unknown_event_type',
  'sse_unsupported_part',
  'sse_unsupported_response',
  'sse_stream_incomplete',
])
const KEEPER_TURN_OUTCOMES = new Set([
  'visible_reply',
  'continuation_checkpoint',
  'external_effect_completed',
  'external_effect_pending',
  'no_visible_reply',
])

function exactCustomObject(
  value: unknown,
  name: string,
  allowedFields: readonly string[],
): SafeParseResult<Record<string, unknown>> {
  if (!isRecord(value)) {
    return fail('ag_ui_event.value', `Expected ${name} object payload`)
  }
  const allowed = new Set(allowedFields)
  const unknown = Object.keys(value).find(key => !allowed.has(key))
  return unknown
    ? fail(`ag_ui_event.value.${unknown}`, `Unexpected ${name} payload field`)
    : ok(value)
}

function requiredString(
  value: Record<string, unknown>,
  field: string,
): SafeParseResult<true> {
  return typeof value[field] === 'string' && value[field].trim() !== ''
    ? ok(true)
    : fail(`ag_ui_event.value.${field}`, `Expected non-empty ${field}`)
}

function requiredInteger(
  value: Record<string, unknown>,
  field: string,
  minimum = 0,
): SafeParseResult<true> {
  const fieldValue = value[field]
  return typeof fieldValue === 'number'
    && Number.isSafeInteger(fieldValue)
    && fieldValue >= minimum
    ? ok(true)
    : fail(`ag_ui_event.value.${field}`, `Expected ${field} integer >= ${minimum}`)
}

function optionalString(
  value: Record<string, unknown>,
  field: string,
): SafeParseResult<true> {
  return value[field] === undefined || (typeof value[field] === 'string' && value[field].trim() !== '')
    ? ok(true)
    : fail(`ag_ui_event.value.${field}`, `Expected non-empty optional ${field}`)
}

function validateUsage(value: unknown): SafeParseResult<true> {
  const result = exactCustomObject(value, 'usage', [
    'input_tokens',
    'output_tokens',
    'total_tokens',
    'cache_creation_input_tokens',
    'cache_read_input_tokens',
    'cost_usd',
  ])
  if (!result.success) return result
  for (const field of [
    'input_tokens',
    'output_tokens',
    'total_tokens',
    'cache_creation_input_tokens',
    'cache_read_input_tokens',
  ]) {
    const valid = requiredInteger(result.data, field)
    if (!valid.success) return valid
  }
  return result.data.cost_usd === undefined
    || (typeof result.data.cost_usd === 'number' && Number.isFinite(result.data.cost_usd))
    ? ok(true)
    : fail('ag_ui_event.value.usage.cost_usd', 'Expected finite cost_usd')
}

// KEEPER_STREAM_MESSAGE_DELTA usage carries cumulative counters and emits
// only the ones the wire actually reported, so every field is optional and
// there is no total_tokens or cost_usd. Requiring the full set here silently
// dropped every classic (output-only) delta once the producer stopped
// zero-filling unreported counters.
function validateDeltaUsage(value: unknown): SafeParseResult<true> {
  const result = exactCustomObject(value, 'usage', [
    'input_tokens',
    'output_tokens',
    'cache_creation_input_tokens',
    'cache_read_input_tokens',
  ])
  if (!result.success) return result
  for (const field of [
    'input_tokens',
    'output_tokens',
    'cache_creation_input_tokens',
    'cache_read_input_tokens',
  ]) {
    if (result.data[field] === undefined) continue
    const valid = requiredInteger(result.data, field)
    if (!valid.success) return valid
  }
  return ok(true)
}

function validateKeeperCustomPayload(
  name: KeeperChatCustomEventName,
  payload: unknown,
): SafeParseResult<true> {
  if ([
    'KEEPER_CONNECTED',
    'KEEPER_STREAM_MESSAGE_STOP',
    'KEEPER_STREAM_PING',
  ].includes(name)) {
    return payload === null
      ? ok(true)
      : fail('ag_ui_event.value', `Expected null ${name} payload`)
  }

  if (name === 'KEEPER_EXTERNAL_EFFECT_COMPLETED') {
    // The payload carries the delivery target of the completed surface post
    // (#28374).
    const object = exactCustomObject(payload, name, ['target'])
    if (!object.success) return object
    const target = object.data.target
    if (!isRecord(target)) {
      return fail('ag_ui_event.value.target', `Expected ${name} target object`)
    }
    const targetObject = exactCustomObject(target, name, [
      'kind',
      'channel_id',
      'thread_ts',
    ])
    if (!targetObject.success) return targetObject
    const kind = target.kind
    if (kind === 'dashboard') return ok(true)
    if (kind !== 'discord' && kind !== 'slack') {
      return fail('ag_ui_event.value.target.kind', `Unknown ${name} target kind`)
    }
    return requiredString(targetObject.data, 'channel_id')
  }

  // Total over the event names, so a name added to the contract without a
  // field list stops the build. It used to fall back to an empty list, which
  // made every field the producer sent read as an unexpected one: three
  // events reached main that way and the stream failed with a message about
  // a payload field rather than about the missing contract.
  //
  // The four answered above are listed with the fields they carry, so the
  // record stays a statement about the wire rather than about this function.
  const allowedFields: Record<KeeperChatCustomEventName, readonly string[]> = {
    KEEPER_CONNECTED: [],
    KEEPER_STREAM_MESSAGE_STOP: [],
    KEEPER_STREAM_PING: [],
    KEEPER_EXTERNAL_EFFECT_COMPLETED: ['target'],
    KEEPER_CHAT_OPERATION_ACCEPTED: ['operation_id', 'state', 'queued_count'],
    KEEPER_TOOL_APPROVAL_REQUESTED: [
      'tool_call_id',
      'tool_call_name',
      'args',
      'question',
    ],
    KEEPER_TOOL_APPROVAL_SETTLED: ['tool_call_id', 'outcome'],
    KEEPER_STREAM_MESSAGE_START: ['provider_message_id', 'model', 'usage'],
    KEEPER_STREAM_MESSAGE_DELTA: ['stop_reason', 'usage'],
    KEEPER_CONTENT_BLOCK_START: ['index', 'content_type', 'tool_call_id', 'tool_call_name'],
    KEEPER_CONTENT_BLOCK_STOP: ['index'],
    KEEPER_THINKING_DELTA: ['index', 'delta'],
    KEEPER_THINKING_SIGNATURE_DELTA: ['index', 'signature_bytes'],
    KEEPER_MEDIA_DELTA: ['index', 'media_type', 'source_type', 'media_ref'],
    KEEPER_STREAM_PROTOCOL_ERROR: ['kind', 'index', 'tool_call_id', 'event_type', 'reason', 'raw_bytes'],
    KEEPER_CONTINUATION_CHECKPOINT: ['message', 'request_id'],
    KEEPER_REPLY_DETAILS: ['reply', 'turn_outcome', 'turn_ref'],
    KEEPER_TOOL_RESULT_READY: ['tool_call_id'],
  }
  const object = exactCustomObject(payload, name, allowedFields[name])
  if (!object.success) return object
  const value = object.data

  switch (name) {
    case 'KEEPER_STREAM_MESSAGE_START': {
      const provider = requiredString(value, 'provider_message_id')
      if (!provider.success) return provider
      const model = requiredString(value, 'model')
      if (!model.success) return model
      return value.usage === undefined ? ok(true) : validateUsage(value.usage)
    }
    case 'KEEPER_STREAM_MESSAGE_DELTA': {
      const stopReason = optionalString(value, 'stop_reason')
      if (!stopReason.success) return stopReason
      return value.usage === undefined ? ok(true) : validateDeltaUsage(value.usage)
    }
    case 'KEEPER_CONTENT_BLOCK_START': {
      const index = requiredInteger(value, 'index')
      if (!index.success) return index
      const contentType = requiredString(value, 'content_type')
      if (!contentType.success) return contentType
      const toolId = optionalString(value, 'tool_call_id')
      return toolId.success ? optionalString(value, 'tool_call_name') : toolId
    }
    case 'KEEPER_CONTENT_BLOCK_STOP':
      return requiredInteger(value, 'index')
    case 'KEEPER_TOOL_RESULT_READY':
      return requiredString(value, 'tool_call_id')
    case 'KEEPER_TOOL_APPROVAL_REQUESTED': {
      const toolCallId = requiredString(value, 'tool_call_id')
      if (!toolCallId.success) return toolCallId
      const toolCallName = requiredString(value, 'tool_call_name')
      if (!toolCallName.success) return toolCallName
      const args = requiredString(value, 'args')
      if (!args.success) return args
      return requiredString(value, 'question')
    }
    case 'KEEPER_TOOL_APPROVAL_SETTLED': {
      const toolCallId = requiredString(value, 'tool_call_id')
      if (!toolCallId.success) return toolCallId
      return requiredString(value, 'outcome')
    }
    case 'KEEPER_CHAT_OPERATION_ACCEPTED': {
      const operationId = requiredString(value, 'operation_id')
      if (!operationId.success) return operationId
      const state = requiredString(value, 'state')
      if (!state.success) return state
      return requiredInteger(value, 'queued_count')
    }
    case 'KEEPER_CONNECTED':
    case 'KEEPER_STREAM_MESSAGE_STOP':
    case 'KEEPER_STREAM_PING':
      // Answered above, before the field map: these carry a null payload.
      // Listed so the switch stays total. The nested-shape event is narrowed
      // out of the union by its own early return and cannot appear here.
      return ok(true)
    case 'KEEPER_THINKING_DELTA': {
      const index = requiredInteger(value, 'index')
      return index.success ? requiredString(value, 'delta') : index
    }
    case 'KEEPER_THINKING_SIGNATURE_DELTA': {
      const index = requiredInteger(value, 'index')
      return index.success ? requiredInteger(value, 'signature_bytes') : index
    }
    case 'KEEPER_MEDIA_DELTA': {
      const index = requiredInteger(value, 'index')
      if (!index.success) return index
      for (const field of ['media_type', 'media_ref']) {
        const valid = requiredString(value, field)
        if (!valid.success) return valid
      }
      return value.source_type === 'base64'
        || value.source_type === 'url'
        || value.source_type === 'file_id'
        ? ok(true)
        : fail('ag_ui_event.value.source_type', 'Expected typed media source')
    }
    case 'KEEPER_STREAM_PROTOCOL_ERROR': {
      if (typeof value.kind !== 'string' || !KEEPER_STREAM_PROTOCOL_ERROR_KINDS.has(value.kind)) {
        return fail('ag_ui_event.value.kind', 'Expected typed stream protocol error kind')
      }
      for (const field of ['tool_call_id', 'event_type', 'reason']) {
        const valid = optionalString(value, field)
        if (!valid.success) return valid
      }
      if (value.index !== undefined) {
        const index = requiredInteger(value, 'index')
        if (!index.success) return index
      }
      return value.raw_bytes === undefined ? ok(true) : requiredInteger(value, 'raw_bytes')
    }
    case 'KEEPER_CONTINUATION_CHECKPOINT': {
      const message = requiredString(value, 'message')
      return message.success ? optionalString(value, 'request_id') : message
    }
    case 'KEEPER_REPLY_DETAILS': {
      if (typeof value.reply !== 'string') {
        return fail('ag_ui_event.value.reply', 'Expected reply string')
      }
      const turnRef = requiredString(value, 'turn_ref')
      if (!turnRef.success) return turnRef
      return typeof value.turn_outcome === 'string' && KEEPER_TURN_OUTCOMES.has(value.turn_outcome)
        ? ok(true)
        : fail('ag_ui_event.value.turn_outcome', 'Expected typed Keeper turn outcome')
    }
  }
  // The name reached here from the contract list, so a missing branch is a gap
  // in this function, not an unsupported event. Typed as never so adding a name
  // to the contract without a branch stops the build instead of failing a live
  // turn with a message about the name being unsupported.
  const unhandled: never = name
  return fail('ag_ui_event.name', `No payload contract for ${String(unhandled)}`)
}

function validateKeeperChatAgUiEvent(value: Record<string, unknown>): SafeParseResult<true> {
  if (
    typeof value.type !== 'string'
    || !KEEPER_CHAT_AG_UI_EVENT_TYPES.has(value.type)
  ) {
    return fail('ag_ui_event.type', 'Expected a supported AG-UI event type')
  }
  const allowedFields = KEEPER_CHAT_AG_UI_FIELDS_BY_TYPE.get(value.type)
  const unknown = Object.keys(value).find(key => !allowedFields?.has(key))
  if (unknown) return fail(`ag_ui_event.${unknown}`, `Unexpected ${value.type} event field`)
  if (typeof value.threadId !== 'string' || value.threadId.trim() === '') {
    return fail('ag_ui_event.threadId', 'Expected non-empty AG-UI threadId')
  }
  if (typeof value.timestamp !== 'number' || !Number.isFinite(value.timestamp)) {
    return fail('ag_ui_event.timestamp', 'Expected finite AG-UI timestamp')
  }
  for (const key of [
    'runId',
    'messageId',
    'delta',
    'toolCallId',
    'toolCallName',
    'message',
    'code',
    'name',
  ]) {
    if (value[key] != null && typeof value[key] !== 'string') {
      return fail(`ag_ui_event.${key}`, `Expected AG-UI ${key} to be a string`)
    }
  }
  switch (value.type) {
    case 'RUN_STARTED':
    case 'RUN_FINISHED':
      return typeof value.runId === 'string' && value.runId.trim() !== ''
        ? ok(true)
        : fail('ag_ui_event.runId', 'Expected non-empty AG-UI runId')
    case 'RUN_ERROR':
      return typeof value.message === 'string' && value.message.trim() !== ''
        ? ok(true)
        : fail('ag_ui_event.message', 'Expected non-empty AG-UI error message')
    case 'TEXT_MESSAGE_START':
      if (typeof value.messageId !== 'string' || value.messageId.trim() === '') {
        return fail('ag_ui_event.messageId', 'Expected non-empty AG-UI messageId')
      }
      return value.role === 'assistant' || value.role === 'user'
        ? ok(true)
        : fail('ag_ui_event.role', 'Expected assistant or user AG-UI role')
    case 'TEXT_MESSAGE_CONTENT':
      return typeof value.delta === 'string'
        ? ok(true)
        : fail('ag_ui_event.delta', 'Expected AG-UI text delta')
    case 'TEXT_MESSAGE_END':
      return typeof value.messageId === 'string' && value.messageId.trim() !== ''
        ? ok(true)
        : fail('ag_ui_event.messageId', 'Expected non-empty AG-UI messageId')
    case 'TOOL_CALL_START':
      if (typeof value.toolCallId !== 'string' || value.toolCallId.trim() === '') {
        return fail('ag_ui_event.toolCallId', 'Expected non-empty AG-UI toolCallId')
      }
      return typeof value.toolCallName === 'string' && value.toolCallName.trim() !== ''
        ? ok(true)
        : fail('ag_ui_event.toolCallName', 'Expected non-empty AG-UI toolCallName')
    case 'TOOL_CALL_ARGS':
      if (typeof value.toolCallId !== 'string' || value.toolCallId.trim() === '') {
        return fail('ag_ui_event.toolCallId', 'Expected non-empty AG-UI toolCallId')
      }
      return typeof value.delta === 'string' || typeof value.snapshot === 'string'
        ? ok(true)
        : fail('ag_ui_event', 'Expected AG-UI tool args delta or snapshot')
    case 'TOOL_CALL_END':
      return typeof value.toolCallId === 'string' && value.toolCallId.trim() !== ''
        ? ok(true)
        : fail('ag_ui_event.toolCallId', 'Expected non-empty AG-UI toolCallId')
    case 'CUSTOM':
      if (typeof value.name !== 'string' || !isKeeperCustomEventName(value.name)) {
        return fail('ag_ui_event.name', 'Expected a supported Keeper custom event name')
      }
      if (!Object.prototype.hasOwnProperty.call(value, 'value')) {
        return fail('ag_ui_event.value', 'Expected Keeper custom event value')
      }
      return validateKeeperCustomPayload(value.name, value.value)
  }
  return fail('ag_ui_event.type', 'Expected a supported AG-UI event type')
}

function isOptionalString(value: unknown): boolean {
  return value == null || typeof value === 'string'
}

function isOptionalNumber(value: unknown): boolean {
  return value == null || (typeof value === 'number' && Number.isFinite(value))
}

export function isSSEAudioClip(value: unknown): value is SSEAudioClip {
  if (!isRecord(value)) return false
  if (typeof value.token !== 'string') return false
  if (typeof value.mime !== 'string') return false
  if (typeof value.message_text !== 'string') return false
  if (!isOptionalString(value.audio_url)) return false
  if (!isOptionalNumber(value.duration_sec)) return false
  if (!isOptionalString(value.device_id)) return false
  return true
}

function isIgnorableMcpNotification(value: unknown): boolean {
  if (!isRecord(value)) return false
  if (value.jsonrpc !== '2.0') return false
  if (typeof value.method !== 'string') return false
  if (value.method === 'notifications/board') return false
  return value.method.startsWith('notifications/')
}

function isSSEEventType(value: unknown): value is SSEEventType {
  return typeof value === 'string' && (
    FIXED_SSE_EVENT_TYPES.has(value) || isAgentCoreEventType(value)
  )
}

function schema<T>(
  safeParse: (value: unknown) => SafeParseResult<T>,
): SchemaLike<T> {
  return {
    parse(value: unknown): T {
      const result = safeParse(value)
      if (result.success) return result.data
      throw new Error(result.error.issues.map(issue => issue.message).join('; '))
    },
    safeParse,
  }
}

export const SSEEventTypeSchema = schema<SSEEventType>((value) => {
  if (isSSEEventType(value)) return ok(value)
  return fail(undefined, 'Expected a known SSE event type or an agent_core:* event type')
})

export type { SSEEventType }

function validateAttributionOutcome(value: unknown): SafeParseResult<AttributionOutcome> {
  if (!isRecord(value)) return fail('outcome', 'Expected attribution outcome object')
  const kind = value.kind
  switch (kind) {
    case 'passed':
      return ok({ kind })
    case 'policy_failed':
      return typeof value.reason === 'string'
        ? ok({ kind, reason: value.reason })
        : fail('outcome.reason', 'Expected string reason')
    case 'transition_blocked':
      return (
        typeof value.from_state === 'string'
        && typeof value.to_state === 'string'
        && typeof value.reason === 'string'
      )
        ? ok({
            kind,
            from_state: value.from_state,
            to_state: value.to_state,
            reason: value.reason,
          })
        : fail('outcome', 'Expected transition fields')
    case 'partial_pass':
      return (
        typeof value.score === 'number'
        && Number.isFinite(value.score)
        && typeof value.rationale === 'string'
      )
        ? ok({ kind, score: value.score, rationale: value.rationale })
        : fail('outcome', 'Expected partial_pass score and rationale')
    default:
      return fail('outcome.kind', 'Expected known attribution outcome kind')
  }
}

export const AttributionSchema = schema<Attribution>((value) => {
  if (!isRecord(value)) return fail(undefined, 'Expected attribution object')
  if (value.origin !== 'det' && value.origin !== 'nondet') {
    return fail('origin', 'Expected attribution origin')
  }
  if (typeof value.gate !== 'string') {
    return fail('gate', 'Expected attribution gate')
  }
  if (!isRecord(value.evidence)) {
    return fail('evidence', 'Expected attribution evidence object')
  }
  const outcome = validateAttributionOutcome(value.outcome)
  if (!outcome.success) return outcome
  return ok({
    origin: value.origin,
    gate: value.gate,
    evidence: value.evidence,
    outcome: outcome.data,
  })
})

export type { Attribution }

export type SSEMessage = SSEEvent

function malformedKeeperOperationProjection(
  raw: unknown,
  issues: SchemaIssue[],
): SSEMessage | null {
  if (!isRecord(raw) || raw.type !== 'keeper_chat_operation_event') return null
  if (typeof raw.name !== 'string' || raw.name.trim() === '') return null
  if (typeof raw.operation_id !== 'string' || raw.operation_id.trim() === '') return null
  const detail = issues[0]?.message ?? 'invalid Keeper turn event'
  const timestamp = typeof raw.ts_unix === 'number' && Number.isFinite(raw.ts_unix)
    ? raw.ts_unix
    : Date.now() / 1000
  return {
    type: 'keeper_chat_operation_event',
    name: raw.name,
    operation_id: raw.operation_id,
    ts_unix: timestamp,
    ag_ui_event: {
      type: 'RUN_ERROR',
      threadId: `keeper-consumer:${raw.name}`,
      timestamp,
      message: `Keeper stream protocol error: ${detail}`,
      code: 'invalid_event_payload',
    },
  } as SSEMessage
}

export const SSEMessageSchema = schema<SSEMessage>((value) => {
  if (!isRecord(value)) return fail(undefined, 'Expected SSE message object')
  if (!isSSEEventType(value.type)) {
    return fail('type', 'Expected known SSE event type or agent_core:* event type')
  }

  for (const key of STRING_FIELDS) {
    const field = value[key]
    if (field != null && typeof field !== 'string') {
      return fail(key, `Expected ${key} to be a string`)
    }
  }
  for (const key of NUMBER_FIELDS) {
    const field = value[key]
    if (field != null && (typeof field !== 'number' || !Number.isFinite(field))) {
      return fail(key, `Expected ${key} to be a number`)
    }
  }
  for (const key of BOOLEAN_FIELDS) {
    const field = value[key]
    if (field != null && typeof field !== 'boolean') {
      return fail(key, `Expected ${key} to be a boolean`)
    }
  }

  if (
    value.payload != null
    && !isRecord(value.payload)
    && !isAgentCoreEventType(value.type)
  ) {
    return fail('payload', 'Expected payload object')
  }
  if (value.attribution != null) {
    const attribution = AttributionSchema.safeParse(value.attribution)
    if (!attribution.success) return attribution
  }
  if (value.audio != null && !isSSEAudioClip(value.audio)) {
    return fail('audio', 'Expected audio clip object')
  }

  if (value.type === 'keeper_chat_operation_event') {
    if (typeof value.name !== 'string' || value.name.trim() === '') {
      return fail('name', 'Expected non-empty Keeper name')
    }
    if (
      typeof value.operation_id !== 'string'
      || value.operation_id.trim() === ''
    ) {
      return fail('operation_id', 'Expected a non-empty Keeper operation ID')
    }
    if (!isRecord(value.ag_ui_event)) {
      return fail('ag_ui_event', 'Expected an AG-UI event object')
    }
    const agUiEvent = validateKeeperChatAgUiEvent(value.ag_ui_event)
    if (!agUiEvent.success) return agUiEvent
  }

  if (value.type === 'keeper_waiting_inventory_changed') {
    if (typeof value.keeper_name !== 'string' || value.keeper_name.trim() === '') {
      return fail('keeper_name', 'Expected non-empty keeper_name')
    }
    if (value.queue_kind !== 'chat_operation' && value.queue_kind !== 'event_queue') {
      return fail('queue_kind', 'Expected chat_operation or event_queue queue_kind')
    }
  }

  if (value.type === 'agent_core_telemetry_sample') {
    if (typeof value.provider_id !== 'string' || value.provider_id.trim() === '') {
      return fail('provider_id', 'Expected non-empty provider_id')
    }
    if (typeof value.model_id !== 'string' || value.model_id.trim() === '') {
      return fail('model_id', 'Expected non-empty model_id')
    }
    if (!isRecord(value.payload)) {
      return fail('payload', 'Expected telemetry payload object')
    }
    if (!isRecord(value.payload.sample)) {
      return fail('payload.sample', 'Expected telemetry sample object')
    }
    if (
      typeof value.payload.recorded_at !== 'number'
      || !Number.isFinite(value.payload.recorded_at)
    ) {
      return fail('payload.recorded_at', 'Expected finite recorded_at')
    }
  }

  if (value.type === 'keeper_tool_call') {
    if (
      value.disposition !== 'completed'
      && value.disposition !== 'deferred'
      && value.disposition !== 'failed'
    ) {
      return fail(
        'disposition',
        'Expected keeper_tool_call disposition to be completed, deferred, or failed',
      )
    }
  }

  if (value.type === 'keeper_tool_call_evidence_committed') {
    const requiredStrings = [
      'name',
      'tool_name',
      'composition_tool',
      'composition_run_id',
      'composition_node_id',
      'tool_use_id',
    ] as const
    for (const field of requiredStrings) {
      const candidate = value[field]
      if (typeof candidate !== 'string' || candidate.trim() === '') {
        return fail(field, `Expected a non-empty ${field}`)
      }
    }
    if (typeof value.parent_tool_use_id !== 'string') {
      return fail('parent_tool_use_id', 'Expected parent_tool_use_id to be a string')
    }
    if (value.composition_execution !== 'inline' && value.composition_execution !== 'async') {
      return fail('composition_execution', 'Expected inline or async composition_execution')
    }
    if (value.execution_mode !== 'serial' && value.execution_mode !== 'concurrent') {
      return fail('execution_mode', 'Expected serial or concurrent execution_mode')
    }
    for (const field of ['turn', 'planned_index', 'batch_index', 'batch_size'] as const) {
      const candidate = value[field]
      const minimum = field === 'batch_size' ? 1 : 0
      if (typeof candidate !== 'number' || !Number.isInteger(candidate) || candidate < minimum) {
        return fail(field, `Expected an integer ${field}`)
      }
    }
  }

  if (value.type === 'masc/task_claimed') {
    if (typeof value.task_id !== 'string' || value.task_id.trim() === '') {
      return fail('task_id', 'Expected non-empty task_id')
    }
    if (typeof value.agent_name !== 'string' || value.agent_name.trim() === '') {
      return fail('agent_name', 'Expected non-empty agent_name')
    }
  }

  return ok(value as unknown as SSEMessage)
})

/** Schema drift error for SSE boundary.
 *  Matches the GateStatusSchemaDriftError pattern used by Valibot schemas. */
export class SSESchemaDriftError extends Error {
  constructor(
    public readonly issues: readonly SchemaIssue[],
    public readonly raw: unknown,
  ) {
    super(`SSE schema drift: ${issues.map((i) => i.message).join('; ')}`)
    this.name = 'SSESchemaDriftError'
  }
}

// ── Schema-drift log aggregation ──────────────────────────────────────────
// A rejected event is still dropped either way — this section only bounds
// how much console noise a burst of same-kind drops produces. It is a log
// surface change, not a fix for the underlying drop (see PR description for
// which of the 5 kinds fixed 2026-07 were genuine drops vs. still-invalid
// wire data).

// Aggregation window: repeats of the same drift `kind` inside this window
// are counted instead of re-logged; the count is flushed in one summary line
// when the window closes, but only if more than the initial occurrence
// happened (an isolated one-off never gets a second line).
const DRIFT_LOG_WINDOW_MS = 60_000
// Matches the team convention of truncating raw-payload log previews rather
// than dumping arbitrarily large objects into the console.
const DRIFT_LOG_RAW_PREVIEW_LEN = 500

interface DriftWindowState {
  count: number
  timer: ReturnType<typeof setTimeout>
}

const driftWindows = new Map<string, DriftWindowState>()

function driftKindOf(raw: unknown): string {
  if (isRecord(raw) && typeof raw.type === 'string' && raw.type.trim() !== '') return raw.type
  return 'unknown'
}

function truncateRawPreview(raw: unknown): string {
  let serialized: string
  try {
    serialized = JSON.stringify(raw) ?? String(raw)
  } catch {
    serialized = String(raw)
  }
  return serialized.length > DRIFT_LOG_RAW_PREVIEW_LEN
    ? `${serialized.slice(0, DRIFT_LOG_RAW_PREVIEW_LEN)}…`
    : serialized
}

function flushDriftWindow(kind: string, raw: unknown): void {
  const state = driftWindows.get(kind)
  driftWindows.delete(kind)
  if (!state || state.count <= 1) return
  console.warn(
    `[server-push] schema drift, event dropped: kind=${kind} dropped ${state.count} in `
    + `${DRIFT_LOG_WINDOW_MS / 1000}s, first_raw=${truncateRawPreview(raw)}`,
  )
}

/** Test-only: clears aggregation windows (and their pending timers) between
 *  test cases. Production code never calls this — window state naturally
 *  expires after DRIFT_LOG_WINDOW_MS. */
export function _testResetSseSchemaDriftLog(): void {
  for (const state of driftWindows.values()) clearTimeout(state.timer)
  driftWindows.clear()
}

function logSchemaDrift(raw: unknown, issues: readonly SchemaIssue[]): void {
  const kind = driftKindOf(raw)
  const existing = driftWindows.get(kind)
  if (existing) {
    existing.count += 1
    return
  }
  driftWindows.set(kind, {
    count: 1,
    timer: setTimeout(() => flushDriftWindow(kind, raw), DRIFT_LOG_WINDOW_MS),
  })
  // Full raw payload is only useful for local debugging; in production it is
  // replaced by a truncated preview so a single drifting kind cannot flood
  // the console with large objects (see module doc above).
  if (import.meta.env.DEV) {
    console.warn('[server-push] schema drift, event dropped', { issues, raw })
  } else {
    console.warn(`[server-push] schema drift, event dropped: kind=${kind} first_raw=${truncateRawPreview(raw)}`)
  }
}

/** Parse-or-drop boundary. Returns the typed message on success.
 *  On failure logs a rate-limited console.warn with the drift issue and
 *  returns null; the caller drops the event. */
export function parseSSEMessage(raw: unknown): SSEMessage | null {
  if (isIgnorableMcpNotification(raw)) return null
  const result = SSEMessageSchema.safeParse(raw)
  if (result.success) return result.data
  logSchemaDrift(raw, result.error.issues)
  const protocolError = malformedKeeperOperationProjection(raw, result.error.issues)
  if (protocolError) return protocolError
  return null
}
