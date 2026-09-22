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

val install : unit -> unit
(** Install after the detached memory executor. Queue producers never wait for
    this extraction; source selection happens when the latest unit runs. *)

val submit_durable : base_path:string -> keeper_name:string -> unit
(** Submit disk-selected catch-up for this Keeper on the server-owned
    Librarian lane. Each stored progress advance continues to the next unread
    range; an empty backlog, failure, or disabled/invalid setting ends this
    wake. A launch submits its own Keeper's catch-up;
    {!submit_durable_for_unlaunched} submits it at boot for the Keepers that
    did not launch. *)

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
end
