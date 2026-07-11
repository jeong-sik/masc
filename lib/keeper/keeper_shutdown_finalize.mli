(** Durable task settlement and Keeper identity cleanup after an exact lane
    has joined. Every externally visible side effect is either recorded in the
    operation or returned as a typed failure. *)

type error =
  | Store_error of Keeper_shutdown_store.error
  | Unsupported_phase
  | Finalization_blocked of Keeper_shutdown_types.t

val error_to_string : error -> string

val register_remove_pending_confirms_by_target :
  (Workspace.config ->
   target_type:Operator_action_constants.target_type ->
   target_id:string option ->
   (int, string) result) ->
  unit

val run :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry option ->
  Keeper_shutdown_types.t ->
  (Keeper_shutdown_types.t, error) result

module For_testing : sig
  val paused_meta :
    Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

  val remove_pending_confirms_by_target :
    config:Workspace.config ->
    target_type:Operator_action_constants.target_type ->
    target_id:string option ->
    (int, string) result

  val reset_remove_pending_confirms_by_target : unit -> unit
end
