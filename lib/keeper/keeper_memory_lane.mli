(** Per-keeper Librarian execution lane (RFC-0257).

    Detaches post-turn Librarian extraction from the keeper turn lane. Each
    keeper owns one latest-wins drain, so work is serialized within a keeper
    and runs independently across keepers. This replaces the process-global
    [Eio.Semaphore.make 1] in
    [Keeper_librarian_runtime] that previously serialized every keeper's
    librarian work fleet-wide — the opposite of the lane-per-keeper model
    (RFC-0225).

    The unit submitted must be self-contained over immutable values: it reads
    its Eio capabilities from [Eio_context] (the lane binds the executor switch
    via [Eio_context.with_turn_switch] before running it), and must not close
    over mutable turn-local state that a later turn can overwrite. The OCaml
    type system cannot enforce this immutability precondition; callers are
    responsible for passing a closure that only closes over immutable snapshots
    (e.g. [Keeper_meta_contract.keeper_meta], [Workspace.config]) and never over
    mutable turn-local references.

    Librarian work has a fixed process-local bound of one running unit plus one
    overwriteable latest snapshot. Submission outcomes are counted under
    [masc_keeper_memory_lane_*]; per-keeper pending, in-flight, and
    latest-pending gauges are exported with the [librarian] lane label.

    The lane's lifetime is the server's (RFC librarian-lifecycle section 4.3).
    Keeper admission does not open it, a Keeper exit does not fence or cancel
    it, and a Keeper shutdown does not join it: a unit reads Keeper state from
    disk and its Memory commit is the only thing that moves the read position,
    so nothing about it belongs to one Keeper lifecycle. A submission is never
    refused; while a unit runs, the newest submission waits as the latest
    snapshot. Only {!cancel_and_await_librarian}, from a Keeper purge, stops a
    unit early. *)

type outcome =
  | Submitted
      (** Accepted as the running unit or the queued latest snapshot. *)
  | Coalesced
      (** The lane already had one running and one latest unit. The
          prior latest snapshot was replaced atomically by this newer immutable
          snapshot. *)
  | Ran_inline
      (** Executor switch not initialized; the unit ran synchronously in the
          caller so no work is lost (tests, or startup before {!init}). A
          raising unit is contained and emits a metric instead of escaping. *)
  | Dropped
      (** The executor switch could not own the unit. Saturation returns
          {!Coalesced}, not [Dropped]. The drop is counted, never silent. *)

val init : sw:Eio.Switch.t -> unit
(** Record the long-lived switch that owns detached memory fibers. Call once at
    server startup, after [Eio_context.set_switch]. *)

val submit
  :  base_path:string
  -> keeper_name:string
  -> (unit -> unit)
  -> outcome
(** [submit ~base_path ~keeper_name f] runs [f] on [keeper_name]'s Librarian lane.
    With an executor switch, work uses a non-blocking latest-wins drain:
    one running unit plus one overwriteable latest snapshot. When the executor
    is not initialized, [f] runs inline and any exception is contained and
    counted rather than escaping. Outcomes and per-keeper state are exported as
    metrics. *)

type purge_cancel_error =
  | Purge_cancel_wrong_domain
      (** [Keeper_lane.request_cancel] accepts a request only from the domain
          that owns the lane. Call from the owner domain
          ([Eio_context.run_on_owner_domain]). *)
  | Purge_cancel_not_committed of exn

val purge_cancel_error_to_string : purge_cancel_error -> string

val cancel_and_await_librarian
  :  base_path:string
  -> keeper_name:string
  -> (unit, purge_cancel_error) result
(** For a Keeper purge only. Request cancellation of the Librarian unit still
    running for [keeper_name], if any, and wait until its lane has exited, so
    that a unit cannot write the progress file after the purge has deleted it.
    A round moves the read position only after its Memory commit, so cutting
    it short loses nothing (RFC librarian-lifecycle section 4.3). There is no
    time limit: cancellation is requested first, and the wait ends when the
    cancelled fiber has unwound. A cleanup failure on that exit is logged, not
    returned; the unit is gone either way. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if it has no entry). *)

  val await_idle : base_path:string -> keeper_name:string -> unit
  (** Wait until the keeper's current drain, if any, has exited. Observes
      only; nothing is cancelled or changed. A test uses it where production
      has no reason to wait for the Librarian. *)
end
