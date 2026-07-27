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

    Work is split into two independent lanes per keeper ({!lane}). They write
    different stores under their own locks, so serializing them against each
    other bought nothing while making them share one reservation budget: a
    librarian unit holding its mutex across a provider round trip left room for
    only one of the next turn's two units, and the deterministic write has no
    retry. Each lane now has its own mutex and its own budget; ordering within a
    lane is unchanged.

    The deterministic per-keeper reservation bound is controlled by
    [MASC_KEEPER_MEMORY_LANE_MAX_PENDING] (default [2]). Librarian work instead
    has a fixed process-local bound of one running unit plus one overwriteable
    latest snapshot. Submission outcomes are counted under
    [masc_keeper_memory_lane_*]; per-keeper pending, in-flight, and
    latest-pending gauges are exported, all labelled by [lane]. *)

type lane =
  | Deterministic
      (** Local append to the keeper memory bank. One-shot: a drop here is
          permanent, so it must not queue behind provider-backed work. *)
  | Librarian
      (** Provider-backed episode extraction. Holds its lane across the round
          trip. Saturated submissions replace the queued latest snapshot, so
          cleanup remains reliably eventual without blocking the Keeper turn. *)

type outcome =
  | Submitted
      (** Accepted as the running unit or the queued latest snapshot. *)
  | Coalesced
      (** The Librarian lane already had one running and one latest unit. The
          prior latest snapshot was replaced atomically by this newer immutable
          snapshot. Deterministic submissions never return this outcome. *)
  | Ran_inline
      (** Executor switch not initialized; the unit ran synchronously in the
          caller so no work is lost (tests, or startup before {!init}). A
          raising unit is contained and emits a metric instead of escaping. *)
  | Dropped
      (** The executor switch could not own the unit, or the deterministic lane
          was saturated. Librarian saturation returns {!Coalesced}, not
          [Dropped]. The drop is counted, never silent. *)

val init : sw:Eio.Switch.t -> unit
(** Record the long-lived switch that owns detached memory fibers. Call once at
    server startup, after [Eio_context.set_switch]. *)

val submit
  :  base_path:string
  -> keeper_name:string
  -> lane:lane
  -> (unit -> unit)
  -> outcome
(** [submit ~base_path ~keeper_name ~lane f] runs [f] on [keeper_name]'s [lane].
    With an executor switch, deterministic work retains the bounded serialized
    submission policy. Librarian work uses a non-blocking latest-wins drain:
    one running unit plus one overwriteable latest snapshot. When the executor
    is not initialized, [f] runs inline and any exception is contained and
    counted rather than escaping. Outcomes and per-keeper state are exported as
    metrics. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the lane registry and the executor switch. *)

  val pending : base_path:string -> keeper_name:string -> lane:lane -> int option
  (** Current pending count for a keeper's [lane] ([None] if it has no entry). *)
end
