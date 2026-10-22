(** Input checkpoint publication by one already executing Owner child. *)
type t

type error =
  | Owner_failed of Keeper_owner_registry.command_error
  | Source_missing
  | Source_changed
  | Source_read_failed of Keeper_checkpoint_store.checkpoint_cas_error
  | Snapshot_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Retention_unconfirmed of Keeper_checkpoint_store.checkpoint_installation

val error_to_string : error -> string
val destination : t -> Keeper_owner.input_checkpoint_destination
(** The closed destination captured by the original executing Owner child. *)
val prepare : base_path:string -> keeper_name:string -> session_dir:string ->
  trace_id:Keeper_id.Trace_id.t -> source:Agent_core.Checkpoint.t option -> (t, error) result
(** Capture the child and predecessor before dispatch. If input ownership is
    observed, load its exact retained payload and compare the source's entire
    canonical pending request (including run, identity and question). Missing
    source or a consumed-versus-waiting mismatch refuses dispatch. Ordinary
    checkpoint progress need not have identical bytes to the last input change,
    but its messages must retain the exact input checkpoint as a prefix. An
    unproven history cut requires explicit reconciliation before dispatch;
    two pending=None states alone cannot establish consumed-answer lineage. *)
val bind_retired_input_cut : t -> cut:Keeper_input_history_cut.t ->
  seed:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  operation_id:Keeper_chat_operation.Operation_id.t -> execution_digest:string ->
  observed:Keeper_native_call.state -> call:Keeper_native_call.t -> (t, error) result
(** Retain the verified cut, bind its actual seed, then atomically publish input
    ownership and the next native call. A branch compares its captured host
    predecessor and publishes the next seed without changing global input;
    Owner freshly validates the retained native-to-host relationship. Failure
    never grants replay authority. *)
val publish_autonomous : t -> Agent_core.Checkpoint.t -> (t, error) result
val publish_direct : t -> operation_id:Keeper_chat_operation.Operation_id.t ->
  execution_digest:string -> call_id:string -> observed:Keeper_checkpoint_ref.t ->
  Agent_core.Checkpoint.t -> (t * Keeper_checkpoint_ref.t, error) result
(** Retain exact bytes durably, then publish with the captured Owner witness.
    Installed plus auxiliary facts remain an error carrying the installation;
    neither uncertain retention nor uncertain Owner commit permits replay.
    Session locks are released before entering the Owner mailbox. *)
