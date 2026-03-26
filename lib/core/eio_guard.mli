(** Eio_guard — Dual-mode mutex guard for pre/post Eio runtime.

    Before {!enable} is called, all guard functions execute [f] directly
    (single-threaded, no locking needed). After {!enable}, they acquire
    the given [Eio.Mutex.t] before running [f].

    Call {!enable} once inside [Eio_main.run]. *)

val enable : unit -> unit
(** Activate mutex guards. Call once after Eio runtime starts. *)

val is_ready : unit -> bool
(** [true] after {!enable} has been called. *)

val with_mutex : Eio.Mutex.t -> (unit -> 'a) -> 'a
(** Acquire read-write lock if Eio is ready, run [f] directly otherwise. *)

val with_rw : Eio.Mutex.t -> (unit -> 'a) -> 'a
(** Read-write guard with exception fallback (legacy). *)

val with_ro : Eio.Mutex.t -> (unit -> 'a) -> 'a
(** Read-only guard with exception fallback (legacy). *)
