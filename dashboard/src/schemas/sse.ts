// Lightweight schema-at-boundary for SSE events from the MCP server.
//
// This module intentionally avoids pulling a generic schema runtime into the
// dashboard hot path. SSE and WebSocket push streams import this parser during
// boot, so keep validation direct and limited to the boundary guarantees the
// handlers rely on.

import type {
  Attribution,
  AttributionOutcome,
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

const FIXED_SSE_EVENT_TYPES = new Set([
  'agent_joined',
  'agent_left',
  'broadcast',
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
  'keeper_tool_call',
  'masc/keeper_tool_call',
  'keeper_tool_skipped',
  'keeper_turn_complete',
  'masc/keeper_turn_complete',
  'client_input_approved',
  'client_input_rejected',
  'client_input_updated',
  'governance_param_changed',
  'approval:pending',
  'approval:resolved',
  'project_snapshot',
  'room_truth_snapshot',
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
  'error_text',
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
  'duration_ms',
  'turn',
  'input_tokens',
  'output_tokens',
  'cost_usd',
  'tool_calls_made',
  'total_turns',
])

const BOOLEAN_FIELDS = new Set(['success'])

function ok<T>(data: T): SafeParseSuccess<T> {
  return { success: true, data }
}

function fail<T = never>(path: string | undefined, message: string): SafeParseResult<T> {
  return { success: false, error: { issues: [{ path, message }] } }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
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
    FIXED_SSE_EVENT_TYPES.has(value) || value.startsWith('oas:')
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

  if (value.payload != null && !isRecord(value.payload)) {
    return fail('payload', 'Expected payload object')
  }
  if (value.attribution != null) {
    const attribution = AttributionSchema.safeParse(value.attribution)
    if (!attribution.success) return attribution
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
