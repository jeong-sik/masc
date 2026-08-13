(** Durable task settlement and Keeper identity cleanup after an exact lane
    has joined, or after a dormant metadata owner has been fenced. Every
    externally visible side effect is either recorded in the operation or
    returned as a typed failure. *)

type error =
  | Store_error of Keeper_shutdown_store.error
  | Unsupported_phase
  | Finalization_blocked of Keeper_shutdown_types.t
  | Finalization_draining of Keeper_shutdown_types.t * string
  | Completion_failed of Keeper_shutdown_types.t * string
  | Admission_release_failed of Keeper_shutdown_types.t * string

val error_to_string : error -> string

val register_remove_pending_confirms_by_target :
  (Workspace.config ->
   target_type:Operator_action_constants.target_type ->
   target_id:string option ->
   (int, string) result) ->
  unit

(** Register the process boundary that delivers a typed lifecycle completion
    after [Finalized] is durable and before the Keeper admission fence is
    released. The handler must be repeat-safe because a crash between delivery
    and receipt persistence causes an explicit retry at boot. The stable
    operation id is the deduplication identity for effects that require
    exactly-once projection. *)
val register_completion_handler :
  (Workspace.config ->
   Keeper_shutdown_types.t ->
   Keeper_shutdown_types.completion_action ->
   (unit, string) result) ->
  unit

val run :
  config:Workspace.config ->
  entry:Keeper_registry.registry_entry option ->
  Keeper_shutdown_types.t ->
  (Keeper_shutdown_types.t, error) result

(** [admission_already_released_by_removal ~config operation error] holds when
    [error] says the Keeper owner is absent from the registry and the keeper's
    metadata is gone from the store: the keeper was removed outright, so the
    admission fence this operation wants to release no longer exists — the
    removal itself achieved the release. Logs one info line when true. A
    leftover meta without its owner keeps the error, mirroring the
    [remove_meta_file] cross-check. *)
val admission_already_released_by_removal :
     config:Workspace.config
  -> Keeper_shutdown_types.t
  -> Keeper_owner_registry.command_error
  -> bool

module For_testing : sig
  val paused_meta :
    Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

  val dead_tombstone_meta :
    Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

  val remove_pending_confirms_by_target :
    config:Workspace.config ->
    target_type:Operator_action_constants.target_type ->
    target_id:string option ->
    (int, string) result

  val reset_remove_pending_confirms_by_target : unit -> unit
  val reset_completion_handler : unit -> unit

end
