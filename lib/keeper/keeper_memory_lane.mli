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

type librarian_join_outcome =
  | No_librarian_work
  | Librarian_joined of Keeper_lane.outcome
  | Librarian_join_failed of string

val cancel_and_join_librarian
  :  base_path:string
  -> keeper_name:string
  -> librarian_join_outcome
(** Cancel the exact detached Librarian drain owned by [keeper_name] and wait
    until its provider/tool scope and cleanup have joined. A Keeper lifecycle
    boundary must call this before publishing its own terminal state. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if it has no entry). *)
end
