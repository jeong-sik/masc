(** Executor_pool_ref — shared reference to the [Eio.Executor_pool].

    Set once at server startup ([server_runtime_bootstrap.ml]); read
    by dashboard compute and (future) chain adapter offloading. Backed
    by [Atomic.t] (not a plain [ref]) so cross-domain workers see a
    consistent view without explicit memory barriers. *)

val get : unit -> Eio.Executor_pool.t option
(** [None] before {!set} or in test environments without a pool. *)

val set : Eio.Executor_pool.t -> unit
(** Install the pool reference. Idempotent overwrite. *)

val set_read : Eio.Executor_pool.t -> unit
(** Install the read pool (RFC-0204 L3). The submits below send work from a
    {!Pool_lane.Read} fiber there and everything else to the pool of {!set}.
    Without a read pool, reads use the pool of {!set}. *)

val in_worker_context : unit -> bool
(** Whether the current domain is executing a closure submitted through this
    shared pool reference or through {!Domain_pool}. Nested shared-pool
    adapters use this to run inline instead of waiting on the worker that is
    already executing them. *)

val with_worker_context : (unit -> 'a) -> 'a
(** Run a closure marked as pool work, so {!in_worker_context} holds inside
    it, on a domain with the tuned minor heap ({!Minor_heap.tune}). Every
    pool job enters through it: this module's submits and {!Domain_pool}'s. *)

module For_testing : sig
  val with_pool_option :
    Eio.Executor_pool.t option -> (unit -> 'a) -> 'a
  (** Install an exact optional pool for the dynamic extent of the callback. *)

  val with_pool : Eio.Executor_pool.t -> (unit -> 'a) -> 'a
  (** Install a pool only for the dynamic extent of the callback, then restore
      the exact previous option even when the callback raises. *)

  val with_read_pool : Eio.Executor_pool.t -> (unit -> 'a) -> 'a
  (** {!with_pool} for the read pool. *)
end

type strict_submit_error =
  | Pool_unavailable
  | Caller_not_in_eio
  | Work_failed of Eio.Exn.with_bt
  | Submission_failed of Eio.Exn.with_bt

val strict_submit_error_to_string : strict_submit_error -> string

val submit_strict :
  ?weight:float ->
  name:string ->
  (unit -> 'a) ->
  ('a, strict_submit_error) result
(** Submit [f] exactly once to an installed pool from an Eio fiber.

    Missing pools and non-Eio callers return typed errors without invoking
    [f]. A [Work_failed] result means [f] ran exactly once and raised;
    [Submission_failed] is reserved for executor infrastructure failure. The
    closure is never replayed inline. Cancellation is re-raised with its
    original backtrace at both layers. Entered worker cleanup is joined
    before caller cancellation returns; blocking or protected work can
    delay it. Pending entry is retired when cancellation wins its entry race. *)

val submit_or_inline : ?weight:float -> name:string -> (unit -> 'a) -> 'a
(** [name] names the work in {!Pool_wait} and the trace; callers pass
    [__FUNCTION__] (RFC-0474 L4c).

    Run [f] on an Executor_pool worker (a real Eio fiber under
    [Eio.Switch.run], so effect-based ops keep their handlers), or inline
    in the current fiber when no pool is installed (tests, pre-init), when
    outside Eio, or when already running on the shared worker. A worker or
    submission failure propagates without replaying [f] on the caller.

    Cancelling the caller also cancels a running worker's Eio context.
    Cancellation is cooperative: blocking Eio operations are interrupted,
    while CPU loops and blocking system calls must yield before stopping.
    Work still waiting for pool capacity is withdrawn without invoking [f].
    The caller joins entered worker cleanup before returning cancellation.

    A nested call already running on this shared pool also runs inline. Its
    worker has a live Eio context, while submitting back to a saturated pool
    would wait for the worker currently occupied by the outer call.

    Unlike [Eio_unix.run_in_systhread], the closure runs with a live
    [Cancel.Get_context] handler, so code that takes an [Eio.Mutex]
    (e.g. via [Keeper_fs.ensure_dir]) does not raise [Effect.Unhandled]
    and cannot poison the mutex.  Re-raises [Eio.Cancel.Cancelled]. *)
