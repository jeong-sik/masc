(** Eio_guard — Dual-mode mutex guard for pre/post Eio runtime.

    Before {!enable} is called, all guard functions execute [f] directly
    (single-threaded, no locking needed). After {!enable}, they acquire
    the given [Eio.Mutex.t] before running [f].

    Call {!enable} once inside [Eio_main.run]. *)

val enable : unit -> unit
(** Activate mutex guards. Call once after Eio runtime starts. *)

val disable : unit -> unit
(** Deactivate mutex guards. Useful in tests to reset state between
    [Eio_main.run] invocations so subsequent code outside the Eio
    runtime does not attempt Eio.Mutex operations. *)

val is_ready : unit -> bool
(** [true] after {!enable} has been called. *)

val with_mutex : Eio.Mutex.t -> (unit -> 'a) -> 'a
(** Acquire read-write lock if Eio is ready, run [f] directly otherwise. *)

val with_mutex_ro : Eio.Mutex.t -> (unit -> 'a) -> 'a
(** Acquire read-only lock if Eio is ready, run [f] directly otherwise. *)

val run_in_systhread : (unit -> 'a) -> 'a
(** Run [f] in a system thread if Eio is ready, directly otherwise. *)

val yield_if_ready : unit -> unit
(** Cooperatively yield to the Eio scheduler if the runtime is active.
    No-op before {!enable} or when called from a context where Eio cannot
    currently yield. *)

type yield_meter
(** Counter for periodic cooperative yields in CPU-heavy loops. *)

val create_yield_meter : ?interval:int -> unit -> yield_meter
(** Create a meter that yields every [interval] steps.  Non-positive
    intervals are coerced to 1.  Default: 1000. *)

val yield_step : yield_meter -> unit
(** Count one CPU work unit and call {!yield_if_ready} whenever the
    configured interval is reached. *)
