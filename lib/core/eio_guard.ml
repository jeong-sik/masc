(** Eio_guard — Dual-mode mutex guard for pre/post Eio runtime.

    Before [Eio_main.run] starts, OCaml runs single-threaded and mutexes
    are unnecessary.  Modules that need [Eio.Mutex] at runtime but are
    initialized at module-load time use this guard to skip locking until
    the Eio event loop is active.

    Call {!enable} once inside [Eio_main.run].  Uses [Atomic.t] so the
    flag is safe to read from any domain.

    All guards check the [ready] flag before attempting mutex operations,
    avoiding [Effect.Unhandled] exceptions on the normal code path. *)

let ready = Atomic.make false

let enable () = Atomic.set ready true

let is_ready () = Atomic.get ready

(** Read-write guard: acquires mutex if Eio is ready, runs directly otherwise. *)
let with_mutex mutex f =
  if Atomic.get ready then
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())
  else
    f ()

(** Read-only guard: acquires read lock if Eio is ready, runs directly otherwise. *)
let with_mutex_ro mutex f =
  if Atomic.get ready then
    Eio.Mutex.use_ro mutex (fun () -> f ())
  else
    f ()

(** @deprecated Use {!with_mutex} instead. *)
let with_rw = with_mutex

(** @deprecated Use {!with_mutex_ro} instead. *)
let with_ro = with_mutex_ro
