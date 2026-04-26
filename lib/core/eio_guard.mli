(** Eio_guard — Dual-mode mutex guard for pre/post Eio runtime.

    Before {!enable} is called, all guard functions execute [f] directly
    (single-threaded, no locking needed). After {!enable}, they acquire
    the given [Eio.Mutex.t] before running [f].

    Call {!enable} once inside [Eio_main.run]. *)

(** Activate mutex guards. Call once after Eio runtime starts. *)
val enable : unit -> unit

(** Deactivate mutex guards. Useful in tests to reset state between
    [Eio_main.run] invocations so subsequent code outside the Eio
    runtime does not attempt Eio.Mutex operations. *)
val disable : unit -> unit

(** [true] after {!enable} has been called. *)
val is_ready : unit -> bool

(** Acquire read-write lock if Eio is ready, run [f] directly otherwise. *)
val with_mutex : Eio.Mutex.t -> (unit -> 'a) -> 'a

(** Acquire read-only lock if Eio is ready, run [f] directly otherwise. *)
val with_mutex_ro : Eio.Mutex.t -> (unit -> 'a) -> 'a

(** Run [f] in a system thread if Eio is ready, directly otherwise. *)
val run_in_systhread : (unit -> 'a) -> 'a
