(** Eio_guard — Dual-mode guard for Eio and non-Eio callers.

    {!enable} records that shared Eio mutexes are live. Runtime operations
    additionally inspect the current caller because a process-wide ready flag
    does not give raw Domains or systhreads an Eio effect handler.

    Call {!enable} once inside [Eio_main.run]. *)

(** Activate mutex guards. Call once after Eio runtime starts. *)
val enable : unit -> unit

(** Deactivate mutex guards. Useful in tests to reset state between
    [Eio_main.run] invocations so subsequent code outside the Eio
    runtime does not attempt Eio.Mutex operations. *)
val disable : unit -> unit

(** [true] after {!enable} has been called. *)
val is_ready : unit -> bool

(** Actual execution context of the current caller. [ready] is process-wide;
    it does not imply that a raw Domain or systhread has an Eio handler. *)
type execution_context = Eio_fiber | Non_eio

val execution_context : unit -> execution_context
val is_eio_fiber : unit -> bool

type mutex_access = Read_write | Read_only
exception Non_eio_mutex_context of mutex_access

(** Acquire the read-write lock when enabled from an Eio fiber. Runs directly
    before {!enable}; raises {!Non_eio_mutex_context} for a ready non-Eio
    caller. *)
val with_mutex : Eio.Mutex.t -> (unit -> 'a) -> 'a

(** Read-only counterpart of {!with_mutex}. *)
val with_mutex_ro : Eio.Mutex.t -> (unit -> 'a) -> 'a

(** Run [f] in a system thread from an Eio fiber, directly from a non-Eio
    execution context. *)
val run_in_systhread : (unit -> 'a) -> 'a

(** Eio-aware replacement for [Fun.protect].

    When Eio is active, uses [Eio.Switch.run] + [Eio.Switch.on_release]
    so cleanup always runs and cleanup exceptions do not replace the body
    exception.  [Eio.Cancel.Cancelled] always propagates correctly.

    Outside an Eio fiber, falls back to [Fun.protect]. *)
val protect : finally:(unit -> unit) -> (unit -> 'a) -> 'a

(** Cooperatively yield from an Eio fiber; no-op in a non-Eio context. *)
val yield_if_ready : unit -> unit

(** Check cooperative cancellation from an Eio fiber; no-op in a non-Eio
    context. *)
val check_if_ready : unit -> unit

(** Named cooperative yield for scheduler-fair keeper/runtime boundaries.
    Equivalent to {!yield_if_ready}. *)
val fair_yield : unit -> unit

(** Default step interval for CPU-heavy loops.  P0 fair-yield contract: 1000. *)
val default_fair_yield_interval : int

(** Counter for periodic cooperative yields in CPU-heavy loops. Safe to share
    across fibers or domains. *)
type yield_meter

(** Create a meter that yields every [interval] steps.  Non-positive
    intervals are coerced to 1.  Default: {!default_fair_yield_interval}. *)
val create_yield_meter : ?interval:int -> unit -> yield_meter

(** Count one CPU work unit and call {!yield_if_ready} whenever the
    configured interval is reached. *)
val yield_step : yield_meter -> unit
