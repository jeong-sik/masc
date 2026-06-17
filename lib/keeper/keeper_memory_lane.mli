(** Per-keeper memory execution lane (RFC-0252).

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
    over mutable turn-local state that a later turn can overwrite. *)

type outcome =
  | Submitted
      (** Forked onto the keeper's lane and serialized behind its mutex. *)
  | Ran_inline
      (** Executor switch not initialized; the unit ran synchronously in the
          caller so no work is lost (tests, or startup before {!init}). *)
  | Dropped
      (** The keeper's lane was saturated (pending at the bound); the unit was
          discarded. Memory extraction is best-effort, so saturation drops
          rather than blocking the turn. The drop is counted, never silent. *)

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
    executor is not initialized, [f] runs inline. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> int option
  (** Current pending count for a keeper ([None] if the keeper has no entry). *)
end
