/**
 * Keeper composite snapshot schema — the single source of truth for the
 * `/api/v1/keepers/:name/composite` response shape on the dashboard side.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - TS types are derived via `InferOutput<typeof Schema>` — no hand-typed
 *   interface for this endpoint.
 * - `fetchKeeperComposite` MUST pass the raw response through `v.parse`.
 *   Shape drift from the backend (`keeper_composite_observer.ml`
 *   `snapshot_to_json`) raises `CompositeSchemaDriftError`, not
 *   `undefined` access downstream.
 * - Backward tolerance is expressed explicitly here with `v.optional` /
 *   `v.fallback`, not in a post-hoc normalizer buried elsewhere.
 *
 * History: after PR #7334 removed manual_reconcile, the backend stopped
 * emitting `recovery` and `recovery_two_store_sync`. #7412 patched the
 * gap with a hand-rolled normalizer; this schema pilot (#7439) replaces
 * that normalizer with an explicit contract.
 */

import {
  array,
  boolean,
  fallback,
  nullable,
  number,
  object,
  optional,
  string,
  unknown,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

// FSM state fields stay open strings. The backend can ship new variants
// ahead of the dashboard, and coercing an unknown state to Stable/idle/clean
// hides the exact operator signal we need during a drift event. Consumers
// already render unknown strings opaquely through `displayState`.
const KeeperCompositePhaseSchema = string()

const KeeperCompositeTurnPhaseSchema = string()

const KeeperCompositeDecisionStageSchema = string()

const KeeperCompositeCascadeStateSchema = string()

const KeeperCompositeCompactionStageSchema = string()

// LT-16-KCB Phase 3: 6th axis. KCB is counter-based, not a classical
// Closed/Open/Half_open FSM — only three states are observable between
// tool calls because `record_failure` resets `consecutive_count` to 0
// inside the trip transition. See
// `lib/keeper/keeper_failure_circuit_breaker.mli`.
const KeeperCompositeCircuitBreakerStateSchema = string()

const KeeperCompositeAutoRulesSchema = object({
  reflect: boolean(),
  plan: boolean(),
  compact: boolean(),
  handoff: boolean(),
  guardrail_stop: boolean(),
  guardrail_reason: nullable(string()),
  goal_drift: number(),
})

const KeeperCompositeMeasurementSchema = object({
  captured: boolean(),
  auto_rules: optional(KeeperCompositeAutoRulesSchema),
})

const KeeperCompositeInvariantsSchema = object({
  phase_turn_alignment: boolean(),
  no_cascade_before_measurement: boolean(),
  compaction_atomicity: boolean(),
  event_priority_monotone: boolean(),
})

const KeeperPhaseDiagnosisRowSchema = object({
  key: string(),
  label: string(),
  priority: number(),
  value: boolean(),
  phase: string(),
  determining: boolean(),
})

const KeeperPhaseDiagnosisSchema = object({
  current_phase: string(),
  derived_phase: string(),
  can_execute_turn: boolean(),
  conditions: object({
    launch_pending: boolean(),
    fiber_alive: boolean(),
    heartbeat_healthy: boolean(),
    turn_healthy: boolean(),
    context_within_budget: boolean(),
    context_handoff_needed: boolean(),
    compaction_active: boolean(),
    handoff_active: boolean(),
    operator_paused: boolean(),
    stop_requested: boolean(),
    restart_budget_remaining: boolean(),
    backoff_elapsed: boolean(),
    guardrail_triggered: boolean(),
    drain_complete: boolean(),
    context_overflow: boolean(),
    compact_retry_exhausted: boolean(),
    terminal_failure_latched: boolean(),
  }),
  determining_condition: nullable(string()),
  rows: array(KeeperPhaseDiagnosisRowSchema),
})

const KeeperLastOutcomeSchema = object({
  turn_id: number(),
  ended_at: number(),
  decision_stage: KeeperCompositeDecisionStageSchema,
  cascade_state: KeeperCompositeCascadeStateSchema,
  selected_model: nullable(string()),
})

const KeeperCompositeExecutionSchema = object({
  latest_receipt_present: boolean(),
  recorded_at: nullable(string()),
  outcome: nullable(string()),
  terminal_reason_code: nullable(string()),
  operator_disposition: nullable(string()),
  operator_disposition_reason: nullable(string()),
  model_used: nullable(string()),
  stop_reason: nullable(string()),
  tool_contract_result: nullable(string()),
  duration_ms: nullable(number()),
  error: nullable(
    object({
      kind: nullable(string()),
      message_preview: nullable(string()),
      message_truncated: boolean(),
    }),
  ),
  cascade: nullable(
    object({
      name: nullable(string()),
      selected_model: nullable(string()),
      attempt_count: nullable(number()),
      fallback_applied: nullable(boolean()),
      outcome: nullable(string()),
      degraded_retry_applied: nullable(boolean()),
      degraded_retry_cascade: nullable(string()),
      fallback_reason: nullable(string()),
    }),
  ),
  tool_surface: nullable(
    object({
      tool_requirement: nullable(string()),
      tool_gate_enabled: nullable(boolean()),
      missing_required_tools: array(string()),
      required_tools: array(string()),
    }),
  ),
})

const KeeperRuntimeAttentionSchema = object({
  state: string(),
  needs_attention: boolean(),
  blocked: boolean(),
  fiber_stop_requested: optional(boolean()),
  reason: nullable(string()),
  raw_phase: nullable(string()),
  is_live: boolean(),
  source: string(),
})

const OperatorRecommendedActionSchema = object({
  action_type: string(),
  target_type: string(),
  target_id: optional(nullable(string())),
  severity: fallback(string(), 'unknown'),
  reason: string(),
  confirm_required: optional(boolean()),
  suggested_payload: optional(unknown()),
  preview: optional(unknown()),
})

export const KeeperCompositeSnapshotSchema = object({
  // Explicit registry identity from new backends. Optional so pinned older
  // backends keep rendering; UI falls back to canonical correlation_id parsing.
  keeper: optional(string()),
  correlation_id: string(),
  run_id: string(),
  ts: number(),
  phase: KeeperCompositePhaseSchema,
  // When `phase` is `Stable`, the backend may carry the underlying raw
  // keeper phase (e.g. `paused`) so the dashboard can tell a true idle
  // Stable from a Stable that masks a non-idle source. Absent on older
  // backends and on non-Stable phases — `optional` + `nullable` matches
  // both the missing-key and explicit-null shapes the backend emits.
  collapsed_from: optional(nullable(string())),
  turn_phase: KeeperCompositeTurnPhaseSchema,
  decision: object({ stage: KeeperCompositeDecisionStageSchema }),
  cascade: object({ state: KeeperCompositeCascadeStateSchema }),
  compaction: object({ stage: KeeperCompositeCompactionStageSchema }),
  // `circuit_breaker` is `optional` during the Phase 2 → Phase 3
  // rollout window: pinned backends that have not yet picked up
  // PR #7801 emit snapshots without this key, and the dashboard must
  // keep rendering instead of hard-failing the parse. Once the
  // backend pin catches up everywhere, a follow-up can drop
  // `optional` (promote the key to required with the `clean` fallback
  // alone).
  circuit_breaker: optional(
    object({ state: KeeperCompositeCircuitBreakerStateSchema }),
  ),
  measurement: KeeperCompositeMeasurementSchema,
  invariants: KeeperCompositeInvariantsSchema,
  fsm_guard_violations: number(),
  phase_diagnosis: optional(KeeperPhaseDiagnosisSchema),
  is_live: boolean(),
  last_outcome: nullable(KeeperLastOutcomeSchema),
  execution: optional(KeeperCompositeExecutionSchema),
  runtime_attention: optional(KeeperRuntimeAttentionSchema),
  recommended_actions: fallback(array(OperatorRecommendedActionSchema), []),
  /** @deprecated kept only for old backend experiments; new payloads use `execution`. */
  latest_receipt: optional(unknown()),
})

export type KeeperCompositeSnapshot = InferOutput<typeof KeeperCompositeSnapshotSchema>
export type KeeperCompositeInvariants = InferOutput<typeof KeeperCompositeInvariantsSchema>
export type KeeperCompositeMeasurement = InferOutput<typeof KeeperCompositeMeasurementSchema>
export type KeeperPhaseDiagnosis = InferOutput<typeof KeeperPhaseDiagnosisSchema>
export type KeeperPhaseDiagnosisRow = InferOutput<typeof KeeperPhaseDiagnosisRowSchema>
export type KeeperLastOutcome = InferOutput<typeof KeeperLastOutcomeSchema>
export type KeeperCompositeExecution = InferOutput<typeof KeeperCompositeExecutionSchema>
export type KeeperRuntimeAttention = InferOutput<typeof KeeperRuntimeAttentionSchema>
export type KeeperCompositePhase = InferOutput<typeof KeeperCompositePhaseSchema>
export type KeeperCompositeTurnPhase = InferOutput<typeof KeeperCompositeTurnPhaseSchema>
export type KeeperCompositeDecisionStage = InferOutput<typeof KeeperCompositeDecisionStageSchema>
export type KeeperCompositeCascadeState = InferOutput<typeof KeeperCompositeCascadeStateSchema>
export type KeeperCompositeCompactionStage = InferOutput<typeof KeeperCompositeCompactionStageSchema>

export class CompositeSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('composite', issues)
  }
}

export function parseKeeperCompositeSnapshot(data: unknown): KeeperCompositeSnapshot {
  return parseOrThrow(CompositeSchemaDriftError, KeeperCompositeSnapshotSchema, data)
}

// ── Fleet composite (LT-16a) ─────────────────────────────
//
// Backend: GET /api/v1/keepers/composite returns every registered
// keeper in one envelope. Reuses the per-keeper snapshot shape so the
// matrix UI (LT-16b, dashboard/src/components/fleet-fsm-matrix.ts) can
// share render logic between single-keeper detail and fleet views.
//
// Each poll bumps the masc_keeper_invariant_violations_total counter
// for any violating keeper (documented poll-triggered behaviour,
// docs/observability/cascade-metrics.md §masc_keeper_invariant_violations_total).

export const FleetCompositeSnapshotSchema = object({
  generated_at: number(),
  count: number(),
  snapshots: array(KeeperCompositeSnapshotSchema),
})

export type FleetCompositeSnapshot = InferOutput<typeof FleetCompositeSnapshotSchema>

export function parseFleetCompositeSnapshot(data: unknown): FleetCompositeSnapshot {
  return parseOrThrow(CompositeSchemaDriftError, FleetCompositeSnapshotSchema, data)
}
