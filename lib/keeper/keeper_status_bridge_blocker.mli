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
(** The [runtime_blocker_class] label the status JSON carries. Readers in
    this process take the variant from {!Keeper_status_bridge.runtime_blocker_surface_opt}
    instead of parsing this label back. The dashboard narrows the label to its
    own closed list ([KEEPER_RUNTIME_BLOCKER_CLASSES]). That list and
    {!all_of_runtime_blocker_class} are each checked against
    [dashboard/src/api/fixtures/runtime-blocker-classes.json], so a label added,
    renamed or removed here fails a test until the fixture and the dashboard
    list change with it. *)

val all_of_runtime_blocker_class : runtime_blocker_class list
(** Every class, in declaration order. *)

(** [summary] is lazy: the [turn_failures] summary reads the receipt store,
    and callers that only need [blocker_class] never force it.
    [signature] is the machine-readable wire the summary replaced, when the
    summary is a human sentence written for one known arm (the fenced empty
    assistant turn): the wire kind and cause text a log search keys on. It
    is [None] wherever the summary already leads with the machine wire, so
    a reader never has to choose between the two fields. *)
type runtime_blocker_surface = {
  blocker_class : runtime_blocker_class;
  summary : string Lazy.t;
  signature : string option;
}

(** [latest_receipt] is read only for [Turn_consecutive_failures], whose
    count carries no cause; the summary then names the newest receipt's
    terminal reason when that receipt is a failed turn. *)
val runtime_blocker_surface_of_failure_reason :
  latest_receipt:(unit -> Keeper_execution_receipt.latest_receipt_reading) ->
  Keeper_registry.failure_reason -> runtime_blocker_surface option

