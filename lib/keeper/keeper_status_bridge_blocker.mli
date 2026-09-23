(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** [summary] is lazy: the [turn_failures] summary reads the receipt store,
    and callers that only need [blocker_class] never force it. *)
type runtime_blocker_surface = {
  blocker_class : string;
  summary : string Lazy.t;
}

val blocker_class_of_core_error :
  Agent_core.Error.t -> blocker_class option

(** [latest_receipt] is read only for [Turn_consecutive_failures], whose
    count carries no cause; the summary then names the newest receipt's
    terminal reason when that receipt is a failed turn. *)
val runtime_blocker_surface_of_failure_reason :
  latest_receipt:(unit -> Keeper_execution_receipt.latest_receipt_reading) ->
  Keeper_registry.failure_reason -> runtime_blocker_surface option

val is_runtime_exhausted_blocker_class : string -> bool
val is_provider_runtime_blocker_class : string -> bool
val is_fiber_unresolved_blocker_class : string -> bool

