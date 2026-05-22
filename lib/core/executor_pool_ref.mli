(** Executor_pool_ref — shared reference to the [Eio.Executor_pool].

    Set once at server startup ([server_runtime_bootstrap.ml]); read
    by dashboard compute and (future) chain adapter offloading. Backed
    by [Atomic.t] (not a plain [ref]) so cross-domain workers see a
    consistent view without explicit memory barriers. *)

val get : unit -> Eio.Executor_pool.t option
(** [None] before {!set} or in test environments without a pool. *)

val set : Eio.Executor_pool.t -> unit
(** Install the pool reference. Idempotent overwrite. *)

