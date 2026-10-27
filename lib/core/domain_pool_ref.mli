(** Process-wide typed reference to the shared {!Domain_pool}.

    This is the policy-preserving companion to {!Executor_pool_ref}.  Callers
    that only need the raw Eio pool can keep using [Executor_pool_ref]; keeper
    and runtime call sites should prefer this module so IO/CPU weight policy
    stays centralised in {!Domain_pool}. *)

val get : unit -> Domain_pool.t option
val set : Domain_pool.t -> unit
val clear_for_tests : unit -> unit

val domain_count_opt : unit -> int option
(** Current worker-domain count, when the pool has been installed. *)

val submit_io_or_inline : (unit -> 'a) -> 'a
(** Submit IO-bound work to the shared domain pool. Runs inline when the
    process has not installed the pool yet, when the caller is already on the
    shared executor worker, or when the caller is not on an Eio fiber (raw
    systhread/Domain). The worker case prevents a one-domain pool from waiting
    on itself. A raw-domain pool submit would perform Eio effects with no
    handler and raise [Effect.Unhandled]. Job exceptions re-raise; there is no
    inline re-run on failure. *)

val submit_cpu_or_inline : (unit -> 'a) -> 'a
(** CPU-bound variant of {!submit_io_or_inline}, with the same
    absent-pool and non-Eio-caller inline fallback. *)

val run_in_pool_systhread : ?label:string -> (unit -> 'a) -> 'a
(** Run blocking work outside Eio on a system thread of a pool domain.

    [Eio_unix.run_in_systhread] starts the thread on the caller's domain.
    Only one thread of a domain runs OCaml at a time, so while the work
    parses, hashes or encodes, every fiber of that domain waits for the
    domain lock. Called from the main domain, that is HTTP accept and every
    request handler. Here the system thread belongs to a pool domain, held
    by one CPU-weight pool job for as long as the thread runs.

    The work itself sees what it saw under [Eio_unix.run_in_systhread]: it
    runs outside Eio, so code that branches on {!Eio_guard.execution_context}
    takes its blocking branch, and once started it runs to completion. A
    cancelled caller waits for it, then re-raises its cancellation. Work
    still queued for the pool when the caller is cancelled does not run.

    Without an installed pool, or when the caller is already pool work, the
    system thread starts on the caller's domain. A non-Eio caller runs the
    work directly. Exceptions re-raise; the work is never re-run. *)
