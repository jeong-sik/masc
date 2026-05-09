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

(** {1 Resource Cleanup}

    Drop-in replacement for [Fun.protect] that uses [Eio.Switch.on_release]
    when the Eio runtime is active.  Avoids [Fun.Finally_raised] wrapping
    and correctly propagates [Eio.Cancel.Cancelled] through cleanup handlers. *)

(** Eio-aware [Fun.protect] replacement.

    When the Eio runtime is active, uses [Eio.Switch.run] +
    [Eio.Switch.on_release] so that:
    - Cleanup always runs, even on cancellation.
    - Cleanup exceptions are logged as warnings and do not replace the
      body exception (no [Fun.Finally_raised] wrapping).
    - [Eio.Cancel.Cancelled] always propagates.

    Before [enable ()], falls back to [Fun.protect] (single-threaded,
    no Eio context available). *)
let protect ~finally body =
  if Atomic.get ready then
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw finally;
      body ()
    )
  else
    Fun.protect ~finally body

(** Cooperatively yield without raising if the Eio scheduler is unavailable. *)
let yield_if_ready () =
  if Atomic.get ready then
    Safe_ops.protect ~default:() (fun () -> Eio.Fiber.yield ())

let fair_yield = yield_if_ready

let default_fair_yield_interval = 1000

type yield_meter = {
  interval : int;
  steps : int Atomic.t;
}

let create_yield_meter ?(interval = default_fair_yield_interval) () =
  { interval = max 1 interval; steps = Atomic.make 0 }

let yield_step meter =
  let rec bump () =
    let current = Atomic.get meter.steps in
    let next = if current + 1 >= meter.interval then 0 else current + 1 in
    if Atomic.compare_and_set meter.steps current next then next = 0 else bump ()
  in
  if bump () then yield_if_ready ()
