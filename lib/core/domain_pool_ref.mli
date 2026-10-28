(** Process-wide typed reference to the shared {!Domain_pool}.

    This is the policy-preserving companion to {!Executor_pool_ref}.  Callers
    that only need the raw Eio pool can keep using [Executor_pool_ref]; keeper
    and runtime call sites should prefer this module so IO/CPU weight policy
    stays centralised in {!Domain_pool}. *)

val get : unit -> Domain_pool.t option
val set : Domain_pool.t -> unit

val set_read : Domain_pool.t -> unit
(** Install the read pool (RFC-0204 L3). The submits below send work from a
    {!Pool_lane.Read} fiber there and everything else to the pool of {!set};
    without a read pool, reads use the pool of {!set}. *)

val clear_for_tests : unit -> unit
(** Remove both pools. *)

val domain_count_opt : unit -> int option
(** Current worker-domain count, when the pool has been installed. *)

val read_domain_count_opt : unit -> int option
(** Worker-domain count of the read pool, when installed. *)

val submit_io_or_inline : name:string -> (unit -> 'a) -> 'a
(** Submit IO-bound work to the pool {!set_read} or {!set} selects for the
    caller's {!Pool_lane}. [name] names the work in {!Pool_wait} and the
    trace; callers pass [__FUNCTION__] (RFC-0474 L4c). Runs inline when the
    process has not installed the pool yet, when the caller is already on the
    shared executor worker, or when the caller is not on an Eio fiber (raw
    systhread/Domain). The worker case prevents a one-domain pool from waiting
    on itself. A raw-domain pool submit would perform Eio effects with no
    handler and raise [Effect.Unhandled]. Job exceptions re-raise; there is no
    inline re-run on failure. *)

val submit_cpu_or_inline : name:string -> (unit -> 'a) -> 'a
(** CPU-bound variant of {!submit_io_or_inline}, with the same
    absent-pool and non-Eio-caller inline fallback. *)
