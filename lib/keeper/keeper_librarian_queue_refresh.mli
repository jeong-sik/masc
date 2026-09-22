type pass_end =
  | Off
  | Lane_unconfigured
  | Drained
  | Not_committed
  | Stopped of Keeper_librarian_durable_consumer.error
  | Raised of string

type measurement =
  { measured_at : float
  ; last_pass : pass_end
  ; unread : Keeper_librarian_durable_consumer.unread option
  }

val last_measurement : config:Workspace.config -> keeper_name:string -> measurement option
(** Latest completed durable drain observation in this process, scoped to the
    runtime Keeper directory. [None] means no observation; this is never used
    for admission or scheduling. An unread count unavailable at that pass is
    [None], not the prior pass's count. *)

val forget_measurement : config:Workspace.config -> keeper_name:string -> unit
(** Clear after the purge has quiesced the lane and while submissions remain
    excluded, so a deleted keeper's observations, including measured CLI input
    capacity, cannot outlive its identity. *)


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
(** Submit disk-selected catch-up for this Keeper on the server-owned
    Librarian lane. Each stored progress advance continues to the next unread
    range; an empty backlog, failure, or disabled/invalid setting ends this
    wake. A launch submits its own Keeper's catch-up;
    {!submit_durable_for_unlaunched} submits it at boot for the Keepers that
    did not launch. No process-local remembered closure participates. *)

val unlaunched_keeper_names
  :  persisted:string list
  -> launched:string list
  -> string list
(** The [persisted] names, in their order, that are not in [launched]. *)

val submit_durable_for_unlaunched
  :  base_path:string
  -> persisted:string list
  -> launched:string list
  -> string list
(** The boot scan (RFC librarian-lifecycle section 8, stage 4, item 2).
    Called once by the autoboot subsystem after
    [Runtime_startup_state.await_available]: for every persisted Keeper that
    autoboot did not launch (excluded, fenced by a durable shutdown, failed to
    boot, or autoboot disabled) it submits the same durable catch-up a launch
    would have, and returns the names it submitted for. A Keeper that boots
    later on retry submits its own; the lane runs the two in order and the
    second finds nothing unread. *)

val run_completed_turn : base_path:string -> keeper_name:string -> unit
(** Drain successful durable Agent-Core ranges, then attempt an official-client
    closure when one exists. Runtime entry records an attempt, not extraction
    or commit success. A pre-entry refusal leaves the input pending. *)

module For_testing : sig
  val run_continuity : ?cli_runner:Keeper_lane_cli_oneshot.runner ->
    base_path:string -> keeper_name:string -> unit -> unit
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
