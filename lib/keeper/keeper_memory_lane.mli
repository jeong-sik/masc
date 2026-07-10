(** Per-keeper memory execution lane (RFC-0257).

    Detaches post-turn memory work (deterministic write, librarian extraction,
    compaction) from the keeper turn lane. Each keeper has one FIFO drain
    worker, so memory work is serialized within a keeper and runs independently
    across keepers. This replaces the process-global [Eio.Semaphore.make 1] in
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

    Submissions append immutable work closures and return without waiting for
    earlier memory work; the worker processes every accepted unit in turn
    order. Submission outcomes are counted under [masc_keeper_memory_lane_*]
    and per-keeper pending / in-flight gauges are exported.

    The FIFO owns closures for the lifetime of the server executor switch; it
    is not a restart-durable job store. Switch shutdown explicitly abandons,
    counts, and logs unfinished units. *)

type outcome =
  | Submitted
      (** Accepted by the keeper's FIFO and owned by its drain worker. *)
  | Ran_inline
      (** Executor switch not initialized; the unit ran synchronously in the
          caller so no work is lost (tests, or startup before {!init}). A
          raising unit is contained and emits a metric instead of escaping. *)
  | Dropped
      (** The executor switch could not own the unit (shutdown or worker-spawn
          failure). Accepted work is never dropped merely because earlier
          memory work is still running. Exceptional abandonment is counted and
          logged. *)

val init : sw:Eio.Switch.t -> unit
(** Record the long-lived switch that owns detached memory fibers. Call once at
    server startup, after [Eio_context.set_switch]. *)

val submit
  :  base_path:string
  -> keeper_name:string
  -> (unit -> unit)
  -> outcome
(** [submit ~base_path ~keeper_name f] runs [f] on [keeper_name]'s memory lane.
    When the executor switch is set, [f] is appended to that keeper's FIFO and
    drained by one worker. The caller does not wait for earlier work. When the
    executor is not initialized, [f] runs inline and any exception is contained
    and counted rather than escaping. Outcomes and per-keeper pending/in-flight
    state are exported as metrics. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if the keeper has no entry). *)
end
