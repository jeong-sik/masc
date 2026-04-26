(** Eio_guard — Dual-mode guard for pre/post Eio runtime.

    Before [Eio_main.run] starts, OCaml runs single-threaded and Eio
    primitives are unavailable.  Modules that need [Eio.Mutex] or
    [Eio_unix.run_in_systhread] at runtime but are initialized at
    module-load time use this guard to skip Eio operations until the
    event loop is active.

    Call {!enable} once inside [Eio_main.run].  Uses [Atomic.t] so the
    flag is safe to read from any domain.

    All guards check the [ready] flag before attempting mutex operations,
    avoiding [Effect.Unhandled] exceptions on the normal code path. *)

let ready = Atomic.make false

let enable () = Atomic.set ready true

let disable () = Atomic.set ready false

let is_ready () = Atomic.get ready

(** {1 Mutex Guards}

    All guards use the [Atomic.t] flag to decide whether the Eio
    runtime is available.  Before [enable ()] is called, the body
    runs without any locking (safe because OCaml is single-threaded
    at module init time). *)

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

(** {1 Systhread Guard} *)

(** Run [f] in a system thread when Eio is active, or directly when
    no Eio runtime is available (e.g. unit tests). *)
let run_in_systhread f =
  if Atomic.get ready then
    Eio_unix.run_in_systhread f
  else
    f ()
