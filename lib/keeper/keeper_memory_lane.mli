(** Per-keeper memory execution lane (RFC-0257).

    Detaches post-turn memory work (deterministic write, librarian extraction,
    compaction) from the keeper turn lane. Each keeper has an explicit FIFO
    queue consumed by at most one worker fiber, so memory work is serialized
    within a keeper and runs independently across keepers. This replaces the
    process-global [Eio.Semaphore.make 1] in
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

    Every accepted unit is retained and serialized; the lane never discards
    memory work because another unit is in flight. Admission fails explicitly
    when the executor cannot own the work. Submission outcomes are counted
    under [masc_keeper_memory_lane_*] and per-keeper pending / in-flight gauges
    are exported. *)

type admission_error =
  | Executor_not_initialized
      (** {!init} has not installed the long-lived executor capability. *)
  | Executor_domain_mismatch
      (** Submission did not occur on the Eio switch's owner domain. *)
  | Executor_stopping
      (** The executor switch is cancelling or has finished. *)
  | Worker_start_failed of exn
      (** Eio did not start the worker after the first unit was reserved. *)

val admission_error_code : admission_error -> string
(** Stable low-cardinality code for logs and metric labels. *)

val admission_error_to_string : admission_error -> string
(** Human-readable detail. Control flow must use the typed constructors, not
    this rendering. *)

val init : sw:Eio.Switch.t -> unit
(** Record the long-lived switch that owns detached memory fibers. Call once at
    server startup, after [Eio_context.set_switch]. *)

val submit
  :  base_path:string
  -> keeper_name:string
  -> (unit -> unit)
  -> (unit, admission_error) result
(** [submit ~base_path ~keeper_name f] admits [f] to [keeper_name]'s FIFO memory
    lane. The first accepted unit starts one worker; overlapping units queue
    behind it without spawning additional fibers. [Ok ()] means the worker is
    active and owns the unit. [Error reason] means the unit was not accepted;
    callers must handle that result explicitly. Provider work never runs in the
    submitting turn fiber. Unit exceptions are contained and counted. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if the keeper has no entry). *)

  val queued : base_path:string -> keeper_name:string -> int option
  (** Number of accepted units waiting behind the active unit. *)

  val active_workers : base_path:string -> keeper_name:string -> int option
  (** [0] or [1], exposing the single-worker invariant for deterministic tests. *)
end
