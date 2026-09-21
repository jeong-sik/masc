type runtime_entry = Not_entered | Entered
(** Whether the post-turn callback reached Librarian runtime. Input preparation
    and live-config refusal return [Not_entered]; [Entered] is not commit success. *)

val remember_turn : base_path:string -> keeper_name:string -> trace_id:string ->
  (meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> runtime_entry) -> unit
(** Retain immutable latest-turn evidence for an official-client turn, which
    has no Agent-Core checkpoint range. Agent-Core turns use the durable store
    and never call this function. *)

val forget_turn : base_path:string -> keeper_name:string -> unit
(** Retire an already-attempted direct official-client closure when the same
    Keeper resumes on an Agent-Core checkpoint. A pending closure may already
    be queued behind another memory-lane unit and is retained until that unit
    can attempt its evidence, then retired by that exact-identity attempt.
    [Not_entered] and exceptions leave it retryable; only [Entered] retires it. *)
val install : unit -> unit
(** Install after the detached memory executor. Queue producers never wait for
    this extraction; source selection happens when the latest unit runs. *)

val submit_durable : base_path:string -> keeper_name:string -> unit
(** Submit disk-selected catch-up after this Keeper's Librarian lifecycle has
    opened. Each stored progress advance continues to the next unread range;
    an empty backlog, failure, or disabled/invalid setting ends this wake.
    Launch admission owns restart catch-up; there is no pre-admission fleet
    scan and no process-local remembered closure participates. *)

val run_completed_turn : base_path:string -> keeper_name:string -> unit
(** Drain successful durable Agent-Core ranges, then attempt an official-client
    closure when one exists. Runtime entry records an attempt, not extraction
    or commit success. A pre-entry refusal leaves the input pending. *)

module For_testing : sig
  val run_durable_with_commit
    :  config:Workspace.config
    -> keeper_name:string
    -> commit:
         (expected_revision:int option
          -> range_id:Keeper_memory_os_current.durable_range_id option
          -> official_range_id:Keeper_memory_os_current.official_range_id option
          -> Keeper_librarian.input
          -> bool)
    -> unit
  (** The production durable reader with a controlled Memory commit edge. *)

  val attempt_remembered : base_path:string -> keeper_name:string ->
    trace_id:string -> meta:Keeper_meta_contract.keeper_meta -> sources_changed:bool ->
    trigger:Keeper_librarian_runtime.trigger -> bool
end
