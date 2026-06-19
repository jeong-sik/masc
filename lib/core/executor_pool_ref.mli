(** Executor_pool_ref — shared reference to the [Eio.Executor_pool].

    Set once at server startup ([server_runtime_bootstrap.ml]); read
    by dashboard compute and (future) chain adapter offloading. Backed
    by [Atomic.t] (not a plain [ref]) so cross-domain workers see a
    consistent view without explicit memory barriers. *)

val get : unit -> Eio.Executor_pool.t option
(** [None] before {!set} or in test environments without a pool. *)

val set : Eio.Executor_pool.t -> unit
(** Install the pool reference. Idempotent overwrite. *)

val submit_or_inline : ?weight:float -> (unit -> 'a) -> 'a
(** Run [f] on an Executor_pool worker (a real Eio fiber under
    [Eio.Switch.run], so effect-based ops keep their handlers), or inline
    in the current fiber when no pool is installed (tests, pre-init).

    Unlike [Eio_unix.run_in_systhread], the closure runs with a live
    [Cancel.Get_context] handler, so code that takes an [Eio.Mutex]
    (e.g. via [Keeper_fs.ensure_dir]) does not raise [Effect.Unhandled]
    and cannot poison the mutex.  Re-raises [Eio.Cancel.Cancelled]. *)

