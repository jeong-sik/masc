(** Eio_guard — Dual-mode mutex guard for pre/post Eio runtime.

    Before [Eio_main.run] starts, OCaml runs single-threaded and mutexes
    are unnecessary.  Modules that need [Eio.Mutex] at runtime but are
    initialized at module-load time use this guard to skip locking until
    the Eio event loop is active.

    Call {!enable} once inside [Eio_main.run].  Uses [Atomic.t] so the
    flag is safe to read from any domain. *)

let ready = Atomic.make false

let enable () = Atomic.set ready true

let is_ready () = Atomic.get ready

let with_mutex mutex f =
  if Atomic.get ready then
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())
  else
    f ()

(** Read-write guard that falls back to direct execution when
    Eio runtime is unavailable (e.g. unit tests). *)
let with_rw mutex f =
  try Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

(** Read-only guard with the same fallback. *)
let with_ro mutex f =
  try Eio.Mutex.use_ro mutex (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()
