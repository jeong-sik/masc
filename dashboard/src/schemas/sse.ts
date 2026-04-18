// Zod schema-at-boundary for SSE events from the MCP server.
//
// Parse gate: the top-level `type` discriminator is validated against a
// closed enum so unknown event names surface as drift instead of becoming
// silent no-ops. All other fields are declared as optional (mirrors the
// existing `SSEEvent` interface) so new backend payload shapes don't hard-
// fail the dashboard — but the field types are still checked when present.
//
// TypeScript SSOT: src/types/sse.ts (SSEEvent interface).
// Phase 1 goal: eliminate the `as SSEEvent` cast in src/sse.ts by giving
// onmessage a checked parse boundary. Phase 2 will split this into a
// per-variant z.discriminatedUnion so handlers can switch exhaustively.

import { z } from 'zod'

// --- Type discriminator (closed enum) -------------------------------------
// Mirror of the non-OAS literals in `SSEEventType` in ../types/sse.ts.
// OAS bridge events stay open by prefix so a newer server does not get
// parse-dropped the moment it adds a new `oas:*` event family.
const FixedSSEEventTypeSchema = z.enum([
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
  'room_truth_snapshot',
  'namespace_truth_snapshot',
  'execution_snapshot',
  'operator_snapshot',
  'operator_digest',
  'transport_health_snapshot',
])

const OasPrefixedEventTypeSchema = z
  .string()
  .regex(/^oas:/, 'Expected an oas:* event type')

export const SSEEventTypeSchema = z.union([
  FixedSSEEventTypeSchema,
  OasPrefixedEventTypeSchema,
])

export type SSEEventType = z.infer<typeof SSEEventTypeSchema>

// --- Attribution envelope (nested discriminated union) --------------------
// OCaml SSOT: lib/attribution.mli. Structurally mirrors AttributionOutcome
// which is a discriminated union on `kind`. Zod's discriminatedUnion
// matches exactly — unknown `kind` fails parse.

const AttributionOutcomeSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('passed') }),
  z.object({
    kind: z.literal('policy_failed'),
    reason: z.string(),
  }),
  z.object({
    kind: z.literal('transition_blocked'),
    from_state: z.string(),
    to_state: z.string(),
    reason: z.string(),
  }),
  z.object({
    kind: z.literal('partial_pass'),
    score: z.number(),
    rationale: z.string(),
  }),
])

export const AttributionSchema = z.object({
  origin: z.enum(['det', 'nondet']),
  // `gate` is intentionally open: known canonical names are documented in
  // the TS SSEEvent AttributionGate union but new gates must not break
  // existing clients.
  gate: z.string(),
  evidence: z.record(z.string(), z.unknown()),
  outcome: AttributionOutcomeSchema,
})

export type Attribution = z.infer<typeof AttributionSchema>

// --- SSE envelope --------------------------------------------------------
// Strict on discriminator (`type`), permissive on payload (every other
// field optional). Unknown fields pass through to preserve forward-
// compat: a newer server emitting a new payload field must not crash
// a slightly older dashboard. Typed fields still reject wrong-type values.
export const SSEMessageSchema = z
  .object({
    type: SSEEventTypeSchema,
    severity: z.string().optional(),
    source: z.string().optional(),
    agent: z.string().optional(),
    from: z.string().optional(),
    from_agent: z.string().optional(),
    message: z.string().optional(),
    content: z.string().optional(),
    task_id: z.string().optional(),
    status: z.string().optional(),
    post_id: z.string().optional(),
    comment_id: z.string().optional(),
    title: z.string().optional(),
    author: z.string().optional(),
    voter: z.string().optional(),
    direction: z.string().optional(),
    hearth: z.string().optional(),
    agent_name: z.string().optional(),
    keeper_name: z.string().optional(),
    event_type: z.string().optional(),
    // Keeper event fields
    name: z.string().optional(),
    generation: z.number().optional(),
    context_ratio: z.number().optional(),
    ts_unix: z.number().optional(),
    from_generation: z.number().optional(),
    to_generation: z.number().optional(),
    from_model: z.string().optional(),
    to_model: z.string().optional(),
    before_tokens: z.number().optional(),
    after_tokens: z.number().optional(),
    saved_tokens: z.number().optional(),
    trigger: z.string().optional(),
    reason: z.string().optional(),
    // Phase transitions
    prev_phase: z.string().optional(),
    new_phase: z.string().optional(),
    event: z.string().optional(),
    // Tool call / skip fields
    tool_name: z.string().optional(),
    duration_ms: z.number().optional(),
    success: z.boolean().optional(),
    error_text: z.string().optional(),
    reason_code: z.string().optional(),
    turn: z.number().optional(),
    phase: z.string().optional(),
    from_state: z.string().optional(),
    to_state: z.string().optional(),
    session_id: z.string().optional(),
    operation_id: z.string().optional(),
    worker_run_id: z.string().optional(),
    // Turn complete enrichment
    model_used: z.string().optional(),
    input_tokens: z.number().optional(),
    output_tokens: z.number().optional(),
    cost_usd: z.number().optional(),
    tool_calls_made: z.number().optional(),
    total_turns: z.number().optional(),
    // Generic OAS payload container
    payload: z.record(z.string(), z.unknown()).optional(),
    // OAS envelope
    correlation_id: z.string().optional(),
    run_id: z.string().optional(),
    // Gate attribution envelope
    attribution: AttributionSchema.optional(),
  })
  .passthrough()

export type SSEMessage = z.infer<typeof SSEMessageSchema>

/** Schema drift error for SSE boundary.
 *  Matches the GateStatusSchemaDriftError pattern used by Valibot schemas. */
export class SSESchemaDriftError extends Error {
  constructor(
    public readonly issues: readonly { path?: string; message: string }[],
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
  const result = SSEMessageSchema.safeParse(raw)
  if (result.success) return result.data
  // Surface drift in dev tools without crashing the stream. Aggregate issues
  // into one warn; keep payload visible so operators can diff server output.
  const issues = result.error.issues.map((i) => ({
    path: i.path.join('.'),
    message: i.message,
  }))
  // eslint-disable-next-line no-console
  console.warn('[SSE] schema drift, event dropped', { issues, raw })
  return null
}
