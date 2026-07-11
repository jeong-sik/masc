(** Durable prepare, admission fence, cancellation, and join for one Keeper
    lane. This module deliberately does not release tasks or remove metadata;
    those are later finalization phases. *)

type request =
  { actor : string
  ; cleanup_intent : Keeper_shutdown_types.cleanup_intent
  }

type error =
  | Registry_lane_replaced
  | Existing_operation of Keeper_shutdown_types.Operation_id.t
  | Task_discovery_failed of string
  | Prepare_persist_failed of Keeper_shutdown_store.error
  | Cancellation_failed of Keeper_shutdown_types.t
  | Join_failed of Keeper_shutdown_types.t
  | Join_record_update_failed of Keeper_shutdown_store.error

val error_to_string : error -> string

val run :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry ->
  request:request ->
  (Keeper_shutdown_types.t, error) result
