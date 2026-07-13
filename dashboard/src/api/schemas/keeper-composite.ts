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

const KeeperCompositeRuntimeStateSchema = string()

const KeeperCompositeCompactionStageSchema = string()

const KeeperCompositeContextActionsSchema = object({
  compact: boolean(),
  handoff: boolean(),
})

const KeeperCompositeMeasurementSchema = object({
  captured: boolean(),
  context_actions: optional(KeeperCompositeContextActionsSchema),
})

const KeeperCompositeInvariantsSchema = object({
  phase_turn_alignment: boolean(),
  no_runtime_before_measurement: boolean(),
  compaction_atomicity: boolean(),
  event_priority_monotone: boolean(),
  phase_derivation_agreement: boolean(),
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
    dead_tombstone_latched: boolean(),
    drain_complete: boolean(),
    context_overflow: boolean(),
  }),
  determining_condition: nullable(string()),
  rows: array(KeeperPhaseDiagnosisRowSchema),
})

const KeeperLastOutcomeSchema = object({
  turn_id: number(),
  ended_at: number(),
  decision_stage: KeeperCompositeDecisionStageSchema,
  runtime_state: KeeperCompositeRuntimeStateSchema,
  selected_model: nullable(string()),
})

const KeeperLiveTurnSchema = object({
  turn_id: number(),
  started_at: number(),
  last_progress_at: number(),
  last_progress_kind: nullable(string()),
  // Surface model + in-flight tool count for the *running* turn (A-PR-2 G2).
  // `optional` so a pinned backend that predates these fields still parses;
  // the live turn object shape is otherwise unchanged.
  selected_model: optional(nullable(string())),
  active_tool_count: optional(number()),
})

// Most recent deliberate skip verdict from the keepalive cycle (A-PR-2 G5).
// Lets operators see *why* an idle keeper is quiet, not just that it is.
const KeeperLastSkipSchema = object({
  ts: number(),
  reasons: array(string()),
})

// Objective turn-attempt history. This field is observability-only.
const KeeperTurnAttemptSchema = object({
  turn_id: number(),
  attempts: number(),
  first_started_at: number(),
})

// Board consumption cursor (A-PR-2 G10): how far the keeper has consumed
// the shared board. Always emitted; `ts=0` / `post_id=null` before any post.
const KeeperBoardCursorSchema = object({
  ts: number(),
  post_id: nullable(string()),
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
  duration_ms: nullable(number()),
  error: nullable(
    object({
      kind: nullable(string()),
      message_preview: nullable(string()),
      message_truncated: boolean(),
    }),
  ),
  runtime: nullable(
    object({
      name: nullable(string()),
      selected_model: nullable(string()),
      attempt_count: nullable(number()),
      fallback_applied: nullable(boolean()),
      outcome: nullable(string()),
      degraded_retry_applied: nullable(boolean()),
      degraded_retry_runtime: nullable(string()),
      fallback_reason: nullable(string()),
    }),
  ),
  claim_scope: optional(unknown()),
  config_drift: optional(unknown()),
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
  execution_current: optional(boolean()),
  stale_execution_receipt: optional(boolean()),
  live_turn_started_at: optional(nullable(number())),
  live_turn_last_progress_at: optional(nullable(number())),
})

const KeeperSecretFileMountSchema = object({
  host_path: string(),
  container_path: string(),
})

const KeeperSecretRootSchema = object({
  root: string(),
  source: string(),
  status: string(),
  configured: boolean(),
  env_count: number(),
  file_count: number(),
})

const KeeperSecretProjectionSchema = object({
  status: string(),
  configured: boolean(),
  root: string(),
  source: string(),
  effective_roots: fallback(array(KeeperSecretRootSchema), []),
  env_count: number(),
  file_count: number(),
  env_names: fallback(array(string()), []),
  file_mounts: fallback(array(KeeperSecretFileMountSchema), []),
  values_validated: boolean(),
  error: nullable(string()),
  next_action: string(),
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

const FsmGuardViolationBucketSchema = object({
  action: string(),
  stage: string(),
  count: number(),
})

// Total run-state classification (#16, 38-bug campaign PR-5). `kind` stays
// an open string for the same reason as the other FSM fields above: a new
// backend `run_state` variant must render opaquely, not vanish behind a
// stale enum. Per-kind fields (`wake_kind`, `queue_depth`, `phase`, ...)
// are `optional` — only the fields relevant to `kind` are populated on the
// wire (see `keeper_composite_observer.ml` `run_state_to_json`).
const KeeperRunStateSchema = object({
  kind: string(),
  wake_kind: optional(string()),
  stimulus_kinds: optional(array(string())),
  started_at: optional(number()),
  active_tool_count: optional(number()),
  queue_depth: optional(number()),
  skip_reasons: optional(array(string())),
  phase: optional(string()),
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
  runtime: object({ state: KeeperCompositeRuntimeStateSchema }),
  compaction: object({ stage: KeeperCompositeCompactionStageSchema }),
  measurement: KeeperCompositeMeasurementSchema,
  invariants: KeeperCompositeInvariantsSchema,
  fsm_guard_violations: number(),
  fsm_guard_violation_breakdown: fallback(array(FsmGuardViolationBucketSchema), []),
  phase_diagnosis: optional(KeeperPhaseDiagnosisSchema),
  is_live: boolean(),
  live_turn: optional(nullable(KeeperLiveTurnSchema)),
  // #16 (38-bug campaign PR-5). `optional` for rollout tolerance: a pinned
  // backend that predates this field omits it and the dashboard must keep
  // rendering rather than raising CompositeSchemaDriftError.
  run_state: optional(nullable(KeeperRunStateSchema)),
  last_outcome: nullable(KeeperLastOutcomeSchema),
  // A-PR-2 additive observability fields. All `optional` for rollout
  // tolerance: a pinned backend that predates PR A-PR-2 omits them and the
  // dashboard must keep rendering rather than raising CompositeSchemaDriftError.
  last_skip: optional(nullable(KeeperLastSkipSchema)),
  turn_attempt: optional(nullable(KeeperTurnAttemptSchema)),
  board_cursor: optional(KeeperBoardCursorSchema),
  board_wakeups: optional(number()),
  idle_seconds: optional(number()),
  last_turn_ts: optional(number()),
  execution: optional(KeeperCompositeExecutionSchema),
  runtime_attention: optional(KeeperRuntimeAttentionSchema),
  secret_projection: optional(KeeperSecretProjectionSchema),
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
export type KeeperLiveTurn = InferOutput<typeof KeeperLiveTurnSchema>
export type KeeperRunState = InferOutput<typeof KeeperRunStateSchema>
export type KeeperLastSkip = InferOutput<typeof KeeperLastSkipSchema>
export type KeeperTurnAttempt = InferOutput<typeof KeeperTurnAttemptSchema>
export type KeeperBoardCursor = InferOutput<typeof KeeperBoardCursorSchema>
export type KeeperCompositeExecution = InferOutput<typeof KeeperCompositeExecutionSchema>
export type KeeperRuntimeAttention = InferOutput<typeof KeeperRuntimeAttentionSchema>
export type KeeperSecretProjection = InferOutput<typeof KeeperSecretProjectionSchema>
export type KeeperSecretFileMount = InferOutput<typeof KeeperSecretFileMountSchema>
export type KeeperCompositePhase = InferOutput<typeof KeeperCompositePhaseSchema>
export type KeeperCompositeTurnPhase = InferOutput<typeof KeeperCompositeTurnPhaseSchema>
export type KeeperCompositeDecisionStage = InferOutput<typeof KeeperCompositeDecisionStageSchema>
export type KeeperCompositeRuntimeState = InferOutput<typeof KeeperCompositeRuntimeStateSchema>
export type KeeperCompositeCompactionStage = InferOutput<typeof KeeperCompositeCompactionStageSchema>

export class CompositeSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('composite', issues)
  }
}

export function parseKeeperSecretProjection(data: unknown): KeeperSecretProjection {
  return parseOrThrow(CompositeSchemaDriftError, KeeperSecretProjectionSchema, data)
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
// docs/observability/runtime-metrics.md §masc_keeper_invariant_violations_total).

export const FleetCompositeSnapshotSchema = object({
  generated_at: number(),
  count: number(),
  snapshots: array(KeeperCompositeSnapshotSchema),
})

export type FleetCompositeSnapshot = InferOutput<typeof FleetCompositeSnapshotSchema>

export function parseFleetCompositeSnapshot(data: unknown): FleetCompositeSnapshot {
  return parseOrThrow(CompositeSchemaDriftError, FleetCompositeSnapshotSchema, data)
}
