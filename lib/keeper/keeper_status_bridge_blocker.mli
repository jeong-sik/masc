(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** What blocks a keeper's runtime, one per [Keeper_registry.failure_reason]
    arm ([Provider_runtime_error] splits on whether it carries a typed
    exhaustion reason). *)
type runtime_blocker_class =
  | Blocked_by_heartbeat_failures
  | Blocked_by_turn_failures
  | Blocked_by_runtime_exhaustion
  | Blocked_by_provider_runtime_error
  | Blocked_by_official_client_recovery
  | Blocked_by_turn_configuration_error
  | Blocked_by_unresolved_fiber
  | Blocked_by_exception
  | Blocked_by_operator_interrupt

val runtime_blocker_class_to_string : runtime_blocker_class -> string
(** The [runtime_blocker_class] label the status JSON carries. The two that
    [Keeper_meta_contract.blocker_class_of_serialized_string] also reads,
    ["runtime_exhausted"] and ["fiber_unresolved"], are spelled as it does. *)

(** [summary] is lazy: the [turn_failures] summary reads the receipt store,
    and callers that only need [blocker_class] never force it. *)
type runtime_blocker_surface = {
  blocker_class : runtime_blocker_class;
  summary : string Lazy.t;
}

(** [latest_receipt] is read only for [Turn_consecutive_failures], whose
    count carries no cause; the summary then names the newest receipt's
    terminal reason when that receipt is a failed turn. *)
val runtime_blocker_surface_of_failure_reason :
  latest_receipt:(unit -> Keeper_execution_receipt.latest_receipt_reading) ->
  Keeper_registry.failure_reason -> runtime_blocker_surface option

