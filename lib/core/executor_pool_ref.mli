(** Executor_pool_ref — shared reference to the [Eio.Executor_pool].

    Set once at server startup ([server_runtime_bootstrap.ml]); read
    by dashboard compute and (future) chain adapter offloading. Backed
    by [Atomic.t] (not a plain [ref]) so cross-domain workers see a
    consistent view without explicit memory barriers. *)

val get : unit -> Eio.Executor_pool.t option
(** [None] before {!set} or in test environments without a pool. *)

val set : Eio.Executor_pool.t -> unit
(** Install the pool reference. Idempotent overwrite. *)

val in_worker_context : unit -> bool
(** Whether the current domain is executing a closure submitted through this
    shared pool reference. Nested shared-pool adapters use this to run inline
    instead of waiting on the worker that is already executing them. *)

module For_testing : sig
  val with_pool_option :
    Eio.Executor_pool.t option -> (unit -> 'a) -> 'a
  (** Install an exact optional pool for the dynamic extent of the callback. *)

  val with_pool : Eio.Executor_pool.t -> (unit -> 'a) -> 'a
  (** Install a pool only for the dynamic extent of the callback, then restore
      the exact previous option even when the callback raises. *)
end

type strict_submit_error =
  | Pool_unavailable
  | Caller_not_in_eio
  | Work_failed of Eio.Exn.with_bt
  | Submission_failed of Eio.Exn.with_bt

val strict_submit_error_to_string : strict_submit_error -> string

val submit_strict :
  ?weight:float ->
  (unit -> 'a) ->
  ('a, strict_submit_error) result
(** Submit [f] exactly once to an installed pool from an Eio fiber.

    Missing pools and non-Eio callers return typed errors without invoking
    [f]. A [Work_failed] result means [f] ran exactly once and raised;
    [Submission_failed] is reserved for executor infrastructure failure. The
    closure is never replayed inline. Cancellation is re-raised with its
    original backtrace at both layers. *)

val submit_or_inline : ?weight:float -> (unit -> 'a) -> 'a
(** Run [f] on an Executor_pool worker (a real Eio fiber under
    [Eio.Switch.run], so effect-based ops keep their handlers), or inline
    in the current fiber when no pool is installed (tests, pre-init).

    A nested call already running on this shared pool also runs inline. Its
    worker has a live Eio context, while submitting back to a saturated pool
    would wait for the worker currently occupied by the outer call.

    Unlike [Eio_unix.run_in_systhread], the closure runs with a live
    [Cancel.Get_context] handler, so code that takes an [Eio.Mutex]
    (e.g. via [Keeper_fs.ensure_dir]) does not raise [Effect.Unhandled]
    and cannot poison the mutex.  Re-raises [Eio.Cancel.Cancelled]. *)
