(** Per-keeper memory execution lane (RFC-0257).

    Detaches post-turn memory work (deterministic write, librarian extraction,
    compaction) from the keeper turn lane. Each keeper has its own mutex, so
    memory work is serialized within a keeper and runs independently across
    keepers. This replaces the process-global [Eio.Semaphore.make 1] in
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

    The per-keeper reservation bound is controlled by
    [MASC_KEEPER_MEMORY_LANE_MAX_PENDING] (default [2]). Submission outcomes
    are counted under [masc_keeper_memory_lane_*] and per-keeper pending /
    in-flight gauges are exported. *)

type outcome =
  | Submitted
      (** Forked onto the keeper's lane and serialized behind its mutex. *)
  | Ran_inline
      (** Executor switch not initialized; the unit ran synchronously in the
          caller so no work is lost (tests, or startup before {!init}). A
          raising unit is contained and emits a metric instead of escaping. *)
  | Dropped
      (** The keeper's lane was saturated (pending at the bound); the unit was
          discarded. Memory extraction is best-effort, so saturation drops
          rather than blocking the turn. The drop is counted, never silent. *)

type idle_submission =
  | Idle_submitted
  | Idle_already_active
  | Idle_executor_unavailable
  | Idle_fork_failed

val init : sw:Eio.Switch.t -> unit
(** Record the long-lived switch that owns detached memory fibers. Call once at
    server startup, after [Eio_context.set_switch]. *)

val submit
  :  base_path:string
  -> keeper_name:string
  -> (unit -> unit)
  -> outcome
(** [submit ~base_path ~keeper_name f] runs [f] on [keeper_name]'s memory lane.
    When the executor switch is set, [f] is forked and serialized behind that
    keeper's mutex; over the pending bound it is dropped and counted. When the
    executor is not initialized, [f] runs inline and any exception is contained
    and counted rather than escaping. The bound, outcomes, and per-keeper
    pending/in-flight state are exported as metrics. *)

val submit_if_idle
  :  base_path:string
  -> keeper_name:string
  -> (Eio.Switch.t -> unit)
  -> idle_submission
(** Submit [f] only when the exact Keeper memory lane has no running or queued
    unit. This is the nonblocking maintenance boundary: an active lane yields
    [Idle_already_active] instead of waiting, queueing duplicate work, or
    dropping it under a numeric capacity policy. A missing executor and a fork
    failure remain distinct typed outcomes. [f] receives the unit-local child
    switch that owns provider and I/O resources. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if the keeper has no entry). *)
end
