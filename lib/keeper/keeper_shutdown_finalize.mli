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
  ?successor_operation_id:Keeper_shutdown_types.Operation_id.t ->
  Keeper_shutdown_types.t ->
  (Keeper_shutdown_types.t, error) result

(** [admission_already_released_by_removal ~config operation error] holds only
    for a [Remove_meta] operation when [error] says the Keeper owner is absent
    from the registry and the keeper's metadata is gone from the store. In
    that state the owner-local fence disappeared with the removed Keeper. The
    caller remains responsible for releasing the exact process-local intake
    fence after any pending completion receipt is durably settled. Logs one
    info line when true. Retain-meta intents and leftover metadata keep the
    error here; [run] itself records a finalized retain-meta operation whose
    owner and metadata are both gone as [Owner_absent] once, instead of
    failing the release again on every boot. *)
val admission_already_released_by_removal :
     config:Workspace.config
  -> Keeper_shutdown_types.t
  -> Keeper_owner_registry.command_error
  -> bool

(** Where boot recovery resumes a replayable [Blocked] operation.
    [Replay_resume settled] resumes [Finalizing_tasks settled]: every owned
    task for {!Keeper_shutdown_types.Replay_settled_tasks} when the Keeper
    actively owns none of them, and otherwise (and for
    {!Keeper_shutdown_types.Replay_unsettled_tasks}) the owned tasks whose
    backlog row carries this operation's release receipt. [Replay_abandon] means
    the Keeper changed after the block. [Replay_unavailable detail] means the
    owner, metadata or backlog could not be read now; the operation stays
    [Blocked] with [detail] as fresh evidence. Performs no writes. *)
type replay_plan =
  | Replay_resume of Keeper_id.Task_id.t list
  | Replay_abandon of Keeper_shutdown_types.boot_replay_abandonment
  | Replay_unavailable of string

val plan_blocked_replay :
  config:Workspace.config ->
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.blocked_replay ->
  replay_plan

module For_testing : sig
  val paused_meta :
    Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

  val remove_pending_confirms_by_target :
    config:Workspace.config ->
    target_type:Operator_action_constants.target_type ->
    target_id:string option ->
    (int, string) result

  val reset_remove_pending_confirms_by_target : unit -> unit
  val reset_completion_handler : unit -> unit

end
