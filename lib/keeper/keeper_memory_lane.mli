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
    latest-pending gauges are exported with the [librarian] lane label. *)

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
  | Rejected_draining
      (** The Keeper lifecycle has begun draining this lane. No post-turn unit
          may cross that terminal boundary; a later Keeper lifecycle must call
          {!begin_librarian_lifecycle} before it can submit. *)

type lifecycle_open_error = Librarian_drain_still_active

val begin_librarian_lifecycle
  :  base_path:string
  -> keeper_name:string
  -> (unit, lifecycle_open_error) result
(** Open the Librarian entry for one newly admitted Keeper lifecycle. This is
    idempotent while the entry is idle and fails when a prior lifecycle still
    owns active work. *)

val lifecycle_open_error_to_string : lifecycle_open_error -> string

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

type librarian_drain_outcome =
  | No_librarian_work
  | Librarian_drained

type librarian_drain_error =
  | Librarian_interrupted of Keeper_lane.outcome
  | Librarian_cleanup_failed of string
  | Librarian_drain_timed_out of float

val librarian_drain_error_to_string : librarian_drain_error -> string

(** Seconds a graceful drain may wait for the Librarian owner lane to exit
    before reporting [Librarian_drain_timed_out]. The cap keeps
    [finish_lifecycle] from blocking forever inside [Eio.Cancel.protect],
    where an outer cancellation cannot interrupt the join. When no global
    Eio clock is available (pre-bootstrap or non-Eio callers) the join stays
    unbounded, matching the previous behaviour. *)
val librarian_drain_timeout_sec : float

type librarian_abort_outcome =
  | Librarian_abort_idle
  | Librarian_abort_requested
  | Librarian_abort_already_in_progress
  | Librarian_abort_already_exited of Keeper_lane.exit
  | Librarian_abort_committed_with_failure of exn

type librarian_abort_error =
  | Librarian_abort_wrong_domain
  | Librarian_abort_not_committed of exn

val librarian_abort_error_to_string : librarian_abort_error -> string

val abort_librarian
  :  base_path:string
  -> keeper_name:string
  -> (librarian_abort_outcome, librarian_abort_error) result
(** Fence new submissions and request cancellation of the exact Librarian
    owner without joining it. Unexpected Keeper exits use this fail-fast path
    so a slow provider cannot delay crash publication or registry cleanup.
    Cancellation outcomes distinguish a committed signal from a request that
    was not delivered; callers must not retry a committed cancellation. *)

val drain_and_join_librarian
  :  base_path:string
  -> keeper_name:string
  -> (librarian_drain_outcome, librarian_drain_error) result
(** Wait for the exact detached Librarian drain owned by [keeper_name] to
    finish its current unit and any retained latest unit, then join its
    provider/tool scope and cleanup. The entry becomes closed to new
    submissions before its owner is inspected, so an accepted unit cannot race
    behind the join. The exact terminal receipt remains available if the owner
    exits before this function is called. Only a [Completed] owner lane returns
    [Librarian_drained]; every other terminal outcome is a typed error. A
    graceful Keeper lifecycle boundary must call this before publishing its own terminal state.
    Parent-switch cancellation still interrupts the drain during process
    shutdown. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if it has no entry). *)

  val set_drain_timeout_sec : float -> unit
  (** Override [librarian_drain_timeout_sec] for tests. *)

  val drain_timeout_sec : unit -> float
  (** The current drain timeout (default or test override). *)
end
