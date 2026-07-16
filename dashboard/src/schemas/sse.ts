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
export const SSE_APPROVAL_SUMMARY_UPDATED_EVENT = 'approval:summary_updated'

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
  SSE_APPROVAL_SUMMARY_UPDATED_EVENT,
  // RFC-0284 §3.2: goal-loop OODA status live delta. Emitted by
  // server_dashboard_http_goal_loop_broadcast.ml. Dispatched by the
  // hydrateDashboardSlice switch in sse-store.ts.
  'goal_loop_status',
  // Nonhierarchical Gate mode transitions (#24332 governance->gate refactor).
  // Emitted by server_routes_http_routes_dashboard.ml.
  'gate_mode_changed',
  // Task claim notifications (#18839). Emitted by
  // lib/task/tool_task_handlers.ml. Routed by the 'masc/task_' PREFIX_ROUTES
  // entry in sse-store.ts.
  'masc/task_claimed',
  // Yjs WebSocket projection layer for live telemetry. Emitted by
  // lib/dashboard/dashboard_yjs.ml. `payload` here is a JSON-stringified
  // string, not a record — see the dedicated payload-shape exception below.
  'dashboard_yjs_update',
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
  // gate_mode_changed
  'mode',
  'previous_mode',
  'actor',
  'changed_at',
  // dashboard_yjs_update
  'kind',
  'frame_base64',
  'encoding',
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
  // dashboard_yjs_update
  'payload_len',
  // masc/task_claimed
  'timestamp',
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

  // dashboard_yjs_update carries a JSON-stringified inner event as `payload`
  // (see lib/dashboard/dashboard_yjs.ml broadcast_update) — a string, not a
  // record, so it is excepted from the generic payload-object rule below and
  // validated in its own dedicated block instead.
  if (
    value.payload != null
    && !isRecord(value.payload)
    && !value.type.startsWith(OAS_EVENT_PREFIX)
    && value.type !== 'dashboard_yjs_update'
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

  if (value.type === 'keeper_chat_queue_changed') {
    if (typeof value.keeper_name !== 'string' || value.keeper_name.trim() === '') {
      return fail('keeper_name', 'Expected non-empty keeper_name')
    }
    if (!Number.isSafeInteger(value.revision) || (value.revision as number) < 0) {
      return fail('revision', 'Expected exact non-negative integer revision')
    }
  }

  if (value.type === 'masc/task_claimed') {
    if (typeof value.task_id !== 'string' || value.task_id.trim() === '') {
      return fail('task_id', 'Expected non-empty task_id')
    }
    if (typeof value.agent_name !== 'string' || value.agent_name.trim() === '') {
      return fail('agent_name', 'Expected non-empty agent_name')
    }
    if (
      !Array.isArray(value.auto_released_task_ids)
      || !value.auto_released_task_ids.every(id => typeof id === 'string')
    ) {
      return fail('auto_released_task_ids', 'Expected an array of task id strings')
    }
  }

  if (value.type === 'dashboard_yjs_update') {
    if (typeof value.kind !== 'string' || value.kind.trim() === '') {
      return fail('kind', 'Expected non-empty kind')
    }
    if (typeof value.payload !== 'string') {
      return fail('payload', 'Expected dashboard_yjs_update payload to be a JSON-encoded string')
    }
    if (!Number.isSafeInteger(value.payload_len) || (value.payload_len as number) < 0) {
      return fail('payload_len', 'Expected non-negative integer payload_len')
    }
    if (typeof value.frame_base64 !== 'string' || value.frame_base64.trim() === '') {
      return fail('frame_base64', 'Expected non-empty frame_base64')
    }
    if (typeof value.encoding !== 'string' || value.encoding.trim() === '') {
      return fail('encoding', 'Expected non-empty encoding')
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
    `[SSE] schema drift, event dropped: kind=${kind} dropped ${state.count} in `
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
    console.warn('[SSE] schema drift, event dropped', { issues, raw })
  } else {
    console.warn(`[SSE] schema drift, event dropped: kind=${kind} first_raw=${truncateRawPreview(raw)}`)
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
  return null
}
