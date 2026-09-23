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

val with_purge_then_catch_up
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> ('a, Keeper_memory_lane.purge_cancel_error) result
(** {!Keeper_memory_lane.with_librarian_purge}, then {!submit_durable} for the
    same Keeper once the purge's exclusion is released. The submission
    follows every exit but cancellation: a purge that ran, one refused (for
    example for unread atoms), a lane-level error, and a raise. The purge
    cancelled the catch-up that was running and discarded the wakes that
    arrived meanwhile; without this the backlog waits for the Keeper's next
    turn, and a purge retry is refused again.

    On [Error Purge_already_in_progress] the submission is always discarded,
    because the other purge still holds the exclusion; that purge submits
    its own catch-up when it ends.

    Call from the lane's owner domain ([Eio_context.run_on_owner_domain]),
    as {!Keeper_memory_lane.with_librarian_purge} and
    {!Keeper_memory_lane.submit} require. This function does not cross
    domains itself. *)

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
  val limited_width :
    config:Workspace.config -> keeper_name:string -> trace_id:string -> int option
  (** The width a later continuity pass will read at, if a refusal left one
      for this trace. *)

  val last_input_capacity :
    config:Workspace.config -> keeper_name:string
    -> Keeper_lane_cli_oneshot.input_capacity option
  (** The CLI limit the next continuity pass fits its range to, if one is
      remembered for this Keeper. *)

  val merge_not_committed :
    Keeper_librarian_runtime.not_committed option
    -> Keeper_librarian_runtime.not_committed
    -> Keeper_librarian_runtime.not_committed
  (** How one pass folds the reports it received: the size verdict of any
      report stands, and the latest detail is kept. *)

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

  val queue_input
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> current:Keeper_librarian.current_selection option
    -> working_context:Keeper_librarian_context.input
    -> Keeper_librarian.input
  (** The input the queue pass hands the Librarian. Reads the Goal store and
      goal-task links for [meta.current_task_id] through the IO pool. *)
end
