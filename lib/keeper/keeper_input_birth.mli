(** Authority produced only by an actual new Keeper trace creation.
    Neither an absent input row nor an empty pending field creates this value. *)
type creation
type session
type seed
type error =
  | Intake_expired
  | Identity_mismatch
  | Session_already_present
  | Initial_save_superseded
  | Snapshot_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Retention_unconfirmed of Keeper_checkpoint_store.checkpoint_installation
  | Initial_source_changed
  | Directory_failed of string

val generate : keeper_name:string -> unit -> (creation, string) result
(** Mint the trace and Keeper UID together; callers cannot supply an old trace. *)
val trace_id : creation -> Keeper_id.Trace_id.t
val keeper_uid : creation -> Keeper_id.Uid.t
val reserve_session : base_path:string ->
  intake_token:Keeper_shutdown_intake_fence.intake_token ->
  creation -> (session, error) result
(** Exclusively create the generated session directory under the original intake. *)
val session_root : session -> string
val retain_initial : session -> checkpoint:Agent_core.Checkpoint.t ->
  outcome:Keeper_checkpoint_store.save_agent_core_outcome -> (seed, error) result
(** The creation producer saves its freshly constructed context into the reserved
    session, then requires an actual Saved outcome and durably retains exact bytes.
    Failed/uncertain writes preserve evidence and grant no seed. Real cancellation
    propagates, including cancellation retained in post-commit auxiliary evidence.
    The expected saved checkpoint must match the canonical bytes. *)
val validate : session_root:string -> keeper_name:string ->
  meta:Keeper_meta_contract.keeper_meta -> seed ->
  (Keeper_checkpoint_ref.t, error) result
(** Recheck the live original intake token, minted identity, current canonical
    bytes and exact retained bytes. Intended for the Owner's empty-actor Create
    command before metadata/dispatch publication. A seed is not dispatch authority.
    Reusing it after its intake ends or for another incarnation is refused. *)
val error_to_string : error -> string
