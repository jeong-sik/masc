(* Keeper_turn_cascade_budget — cascade execution types, fail-open rotation,
   OAS timeout budget resolution, context overflow recovery, keeper pause/resume
   sync, partial-commit continue gate, and context budget resolution.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types
open Keeper_exec_context
module EC = Keeper_error_classify

type cascade_execution = {
  cascade_name : Keeper_cascade_profile.runtime_name;
  max_context_resolution : max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int;
}

val fail_open_rotation_cascades_from_catalog :
  catalog_names:string list ->
  keeper_assignable:string list ->
  string list option

val active_fail_open_rotation_cascades : unit -> string list option

val next_fail_open_cascade_for_turn :
  ?rotation_cascades:string list ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:Keeper_agent_tool_surface.tool_requirement ->
  attempted_cascades:string list ->
  Agent_sdk.Error.sdk_error ->
  EC.degraded_retry option

val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

val record_turn_failure_stress :
  meta:keeper_meta ->
  is_auto_recoverable:bool ->
  consecutive:int ->
  threshold:int ->
  err:Agent_sdk.Error.sdk_error ->
  unit

val oas_timeout_guard_sec : float
(** Retry guard floor (seconds). *)

val min_oas_timeout_budget_sec : float
(** Minimum OAS timeout budget (seconds). *)

val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

type oas_timeout_budget_resolution = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  max_turns : int;
  source : string;
}

val oas_timeout_budget_resolution_to_yojson :
  oas_timeout_budget_resolution -> Yojson.Safe.t

val resolve_bounded_oas_timeout_budget_with_turn_budget :
  is_retry:bool ->
  reserve_degraded_retry_budget:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  oas_timeout_budget_resolution option

val bounded_oas_timeout_for_turn_budget_with_turn_budget :
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  float option

val bounded_oas_timeout_for_turn_budget :
  estimated_input_tokens:int ->
  remaining_turn_budget_s:float ->
  float option

val oas_retry_budget_available_for_turn :
  is_retry:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  bool

val degraded_retry_slot_phase_budget_sec : float
(** Maximum outer-slot hold time before degraded cascade rotation is
    suppressed. This is a guardrail for #12888: once the productive
    phase has already consumed this much wall clock, rotation should end
    the cycle instead of holding the same slot for another provider
    attempt. *)

val degraded_retry_slot_phase_available :
  time_spent_in_turn_s:float -> bool

val reclassify_oas_timeout_for_attempt :
  timeout_budget:oas_timeout_budget_resolution option ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error

val attempt_watchdog_timeout_sec :
  remaining_turn_budget_s:float ->
  oas_timeout_budget_resolution ->
  float
(** Wall-clock watchdog for a single cascade attempt.

    The watchdog fires after the OAS per-attempt budget plus the normal
    finalization guard, but no later than one second before the enclosing
    keeper turn wall-clock timeout. This keeps a hung provider attempt on the
    structured [oas_timeout_budget] path, where degraded cascade rotation can
    still run, instead of falling through to terminal [turn_timeout]. *)

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of EC.degraded_retry
  | Degraded_retry_budget_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

val next_fail_open_cascade_for_turn_with_budget :
  ?rotation_cascades:string list ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:Keeper_agent_tool_surface.tool_requirement ->
  attempted_cascades:string list ->
  estimated_input_tokens:int ->
  max_turns:int ->
  ?time_spent_in_turn_s:float ->
  remaining_turn_budget_s:float ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry_budget_decision

type overflow_retry_plan = {
  retry_max_context : int;
  retry_generation : int;
  compaction : compaction_event;
}

type turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_summary = {
  correlation_id : string option;
  overflow_imminent : turn_event_bus_overflow option;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary :
  turn_event_bus_summary -> turn_event_bus_summary -> turn_event_bus_summary

val recover_context_overflow_retry :
  meta:keeper_meta ->
  base_dir:string ->
  max_cascade_context:int ->
  error:Agent_sdk.Error.sdk_error ->
  overflow_retry_plan option

val summarize_turn_event_bus :
  Agent_sdk.Event_bus.event list -> turn_event_bus_summary

val context_overflow_event_of_error :
  fallback_tokens:int ->
  ?turn_event_bus:turn_event_bus_summary ->
  Agent_sdk.Error.sdk_error ->
  Keeper_state_machine.event

val pause_keeper_for_overflow :
  config:Coord.config ->
  meta:keeper_meta ->
  reason:string ->
  keeper_meta
(** Pause a keeper after unresolved context overflow. Writes meta with merge-CAS
    and dispatches [Compact_retry_exhausted] then [Operator_pause]. Returns the
    paused meta. *)

val sync_keeper_paused_state :
  config:Coord.config ->
  meta:keeper_meta ->
  paused:bool ->
  (keeper_meta, string) result
(** Persist paused/resumed state before mutating the live registry/phase.
    Returns [Error] when disk sync fails so callers can surface the failure
    instead of silently diverging runtime vs persisted state. *)

val current_keeper_meta :
  config:Coord.config ->
  fallback_meta:keeper_meta ->
  keeper_meta
(** Read the latest meta from the registry, falling back to the given
    [fallback_meta] when the registry entry is missing. *)

type post_turn_resilience_handles = {
  resilience_audit_store : Shared_audit.Store.t option;
  resilience_strategy_executor : Resilience.Recovery.strategy_executor option;
  sync_lifecycle_meta :
    Keeper_exec_context.post_turn_lifecycle ->
    Keeper_exec_context.post_turn_lifecycle;
}
(** Runtime handles for the feature-flagged post-turn resilience wire-in.

    When [MASC_RESILIENCE] is off or the audit store cannot be opened, both
    handles are [None] and [sync_lifecycle_meta] is identity. When execution
    pauses a keeper for operator handoff/abort, [sync_lifecycle_meta] folds the
    persisted paused meta back into the lifecycle so the caller's normal final
    meta write does not accidentally unpause it. *)

val resilience_audit_dir :
  config:Coord.config ->
  keeper_name:string ->
  string
(** Per-keeper audit root for resilience recovery envelopes. *)

val post_turn_resilience_handles :
  config:Coord.config ->
  meta:keeper_meta ->
  post_turn_resilience_handles
(** Create per-turn resilience audit/executor handles. The audit store is
    per keeper to respect [Shared_audit.Store]'s single-writer chain
    contract. *)

val enqueue_partial_commit_continue_gate :
  config:Coord.config ->
  meta:keeper_meta ->
  failure_reason:Keeper_registry.failure_reason ->
  committed_tools:string list ->
  error_detail:string ->
  string

val resolved_max_context_for_turn :
  meta:keeper_meta ->
  string list ->
  int
(** Resolve the initial keeper turn context budget. Uses the first available
    model in the cascade rather than the largest fallback model, so lifecycle
    context math matches the provider that will receive the first request. *)
