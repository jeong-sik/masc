// Lightweight schema-at-boundary for SSE events from the MCP server.
//
// This module intentionally avoids pulling a generic schema runtime into the
// dashboard hot path. SSE and WebSocket push streams import this parser during
// boot, so keep validation direct and limited to the boundary guarantees the
// handlers rely on.

import { OAS_EVENT_PREFIX } from '../config/constants'
import type {
  Attribution,
  AttributionOutcome,
  SSEAudioClip,
  SSEEvent,
  SSEEventType,
} from '../types/sse'

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

const FIXED_SSE_EVENT_TYPES = new Set([
  'agent_bound',
  'masc/agent_bound',
  'agent_unbound',
  'masc/agent_unbound',
  'broadcast',
  'masc/broadcast',
  'task_update',
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
  'keeper_guardrail',
  'masc/keeper_guardrail',
  'keeper_phase_changed',
  'keeper_composite_changed',
  'keeper_chat_appended',
  'keeper_chat_queue_changed',
  'keeper_tool_call',
  'masc/keeper_tool_call',
  'keeper_tool_skipped',
  'keeper_turn_complete',
  'masc/keeper_turn_complete',
  // RFC-0266 Phase 4: fusion run-status transitions (running -> completed/failed).
  // Must be in this closed allowlist or parseSSEMessage drops the event at the
  // parse boundary, before the live WS router (sse-store.ts routeServerPushEvent
  // -> SIMPLE_ROUTES['fusion_run_status'] -> refreshFusionRuns) can dispatch it.
  'fusion_run_status',
  'client_input_approved',
  'client_input_rejected',
  'client_input_updated',
  'runtime_param_changed',
  SSE_APPROVAL_PENDING_EVENT,
  SSE_APPROVAL_RESOLVED_EVENT,
  'project_snapshot',
  'namespace_truth_snapshot',
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
  'input_tokens',
  'output_tokens',
  'cost_usd',
  'tool_calls_made',
  'total_turns',
])

const BOOLEAN_FIELDS = new Set(['success', 'reacted', 'tool_io_redacted'])

function ok<T>(data: T): SafeParseSuccess<T> {
  return { success: true, data }
}

function fail<T = never>(path: string | undefined, message: string): SafeParseResult<T> {
  return { success: false, error: { issues: [{ path, message }] } }
}

import { isRecord } from '../lib/type-guards'

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
    FIXED_SSE_EVENT_TYPES.has(value) || value.startsWith(OAS_EVENT_PREFIX)
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
  return fail(undefined, 'Expected a known SSE event type or an oas:* event type')
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

export const SSEMessageSchema = schema<SSEMessage>((value) => {
  if (!isRecord(value)) return fail(undefined, 'Expected SSE message object')
  if (!isSSEEventType(value.type)) {
    return fail('type', 'Expected known SSE event type or oas:* event type')
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

  if (value.payload != null && !isRecord(value.payload) && !value.type.startsWith(OAS_EVENT_PREFIX)) {
    return fail('payload', 'Expected payload object')
  }
  if (value.attribution != null) {
    const attribution = AttributionSchema.safeParse(value.attribution)
    if (!attribution.success) return attribution
  }
  if (value.audio != null && !isSSEAudioClip(value.audio)) {
    return fail('audio', 'Expected audio clip object')
  }

  if (value.type === 'keeper_chat_queue_changed') {
    if (typeof value.keeper_name !== 'string' || value.keeper_name.trim() === '') {
      return fail('keeper_name', 'Expected non-empty keeper_name')
    }
    if (!Number.isSafeInteger(value.revision) || (value.revision as number) < 0) {
      return fail('revision', 'Expected exact non-negative integer revision')
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

/** Parse-or-drop boundary. Returns the typed message on success.
 *  On failure logs a console.warn with the drift issue and returns null;
 *  the caller drops the event. */
export function parseSSEMessage(raw: unknown): SSEMessage | null {
  if (isIgnorableMcpNotification(raw)) return null
  const result = SSEMessageSchema.safeParse(raw)
  if (result.success) return result.data
  // Surface drift in dev tools without crashing the stream. Aggregate issues
  // into one warn; keep payload visible so operators can diff server output.
  console.warn('[SSE] schema drift, event dropped', {
    issues: result.error.issues,
    raw,
  })
  return null
}
