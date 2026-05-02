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
  tool_requirement:string ->
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

val reclassify_oas_timeout_for_attempt :
  timeout_budget:oas_timeout_budget_resolution option ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_budget_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

val next_fail_open_cascade_for_turn_with_budget :
  ?rotation_cascades:string list ->
  is_retry:bool ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:string ->
  attempted_cascades:string list ->
  estimated_input_tokens:int ->
  max_turns:int ->
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
