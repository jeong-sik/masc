(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type runtime_blocker_surface = {
  blocker_class : string;
  summary : string;
}

val blocker_class_of_sdk_error :
  Agent_sdk.Error.sdk_error -> blocker_class option

val runtime_blocker_surface_of_masc_internal_error :
  Keeper_turn_driver.masc_internal_error -> runtime_blocker_surface option

val runtime_blocker_surface_of_typed_class :
  ?summary:string -> blocker_class -> runtime_blocker_surface

val runtime_blocker_surface_of_failure_reason :
  Keeper_registry.failure_reason -> runtime_blocker_surface option

val is_runtime_exhausted_blocker_class : string -> bool
val is_provider_runtime_blocker_class : string -> bool
val is_stale_turn_timeout_blocker_class : string -> bool
val is_fiber_unresolved_blocker_class : string -> bool
val is_gate_replay_repair_blocker_class : string -> bool

val gate_replay_repair_summary :
  approval_id:string ->
  stage:Keeper_internal_error.gate_replay_repair_stage ->
  detail:string ->
  string

val runtime_blocker_surface_class : blocker_class -> blocker_class
val runtime_blocker_class_label : ?summary:string -> blocker_class -> string
