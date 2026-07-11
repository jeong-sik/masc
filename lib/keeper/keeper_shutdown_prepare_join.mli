(** Durable prepare and admission fencing for one Keeper lifecycle cleanup.
    Registered owners additionally cancel and join their exact lane; dormant
    metadata owners begin at the joined phase. This module deliberately does
    not release tasks or remove metadata; those are later finalization phases. *)

type request =
  { actor : string
  ; cleanup_intent : Keeper_shutdown_types.cleanup_intent
  }

type error =
  | Registry_lane_replaced
  | Dormant_registry_lane_present
  | Existing_operation of Keeper_shutdown_types.Operation_id.t
  | Meta_snapshot_missing
  | Meta_snapshot_identity_changed
  | Meta_snapshot_version_changed of
      { expected : int
      ; actual : int
      }
  | Meta_snapshot_read_failed of string
  | Stale_prune_meta_changed
  | Stale_prune_lane_not_paused of Keeper_state_machine.phase
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

(** Persist the shutdown admission fence and ownership snapshot without
    waiting for the current turn or lane. Once this returns [Ok], the durable
    operation owns admission and must be joined or recovered. *)
val prepare :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry ->
  request:request ->
  (Keeper_shutdown_types.t, error) result

(** Fence same-name registration, revalidate the exact durable meta snapshot,
    and persist a [Dormant_meta] operation already joined at [Joined_idle]. *)
val prepare_dormant :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  request:request ->
  (Keeper_shutdown_types.t, error) result

(** Cancel and join the exact lane captured by [prepare]. Never call this
    from that Keeper's admitted turn; lifecycle tools fork it on the server
    switch after returning the accepted operation id. *)
val join_prepared :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry ->
  operation:Keeper_shutdown_types.t ->
  (Keeper_shutdown_types.t, error) result
