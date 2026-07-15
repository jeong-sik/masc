(** Eio_guard — Dual-mode guard for Eio and non-Eio callers.

    Before [Eio_main.run] starts, OCaml runs single-threaded and Eio
    primitives are unavailable.  Modules that need [Eio.Mutex] or
    [Eio_unix.run_in_systhread] at runtime but are initialized at
    module-load time use this guard to skip Eio operations until the
    event loop is active.

    Call {!enable} once inside [Eio_main.run].  Uses [Atomic.t] so the
    flag is safe to read from any domain.

    The process-wide [ready] flag gates shared Eio mutexes. Operations that may
    also be reached from raw Domains inspect the current execution context. *)

let ready = Atomic.make false
let enable () = Atomic.set ready true
let disable () = Atomic.set ready false
let is_ready () = Atomic.get ready

type execution_context = Eio_fiber | Non_eio

let execution_context () =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_fiber
  | exception Effect.Unhandled _ -> Non_eio
;;

let is_eio_fiber () = execution_context () = Eio_fiber

type mutex_access = Read_write | Read_only
exception Non_eio_mutex_context of mutex_access

(** {1 Mutex Guards}

    All guards use the [Atomic.t] flag to decide whether the Eio
    runtime is available.  Before [enable ()] is called, the body
    runs without any locking (safe because OCaml is single-threaded
    at module init time). *)

(** Read-write guard: acquires mutex if Eio is ready, runs directly otherwise. *)
let with_mutex mutex f =
  match Atomic.get ready, execution_context () with
  | false, _ -> f ()
  | true, Eio_fiber -> Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())
  | true, Non_eio -> raise (Non_eio_mutex_context Read_write)
;;

(** Read-only guard: acquires read lock if Eio is ready, runs directly otherwise. *)
let with_mutex_ro mutex f =
  match Atomic.get ready, execution_context () with
  | false, _ -> f ()
  | true, Eio_fiber -> Eio.Mutex.use_ro mutex (fun () -> f ())
  | true, Non_eio -> raise (Non_eio_mutex_context Read_only)
;;

(** {1 Systhread Guard} *)

(** Run [f] in a system thread from an Eio fiber, or directly from a raw Domain
    or other non-Eio execution context.

    A pool system thread has no Eio effect handler.  [f] must therefore
    perform only blocking C/Unix work, never an Eio operation: anything
    that performs an effect (e.g. [Eio.Mutex.use_rw], whose [Cancel.protect]
    performs [Get_context] first) raises [Effect.Unhandled] here, and an
    enclosing [use_rw] then poisons its mutex.  That is the 2026-06-19 keeper
    stall (a poisoned process-shared [dir_mu]); the structural cure is to
    offload Eio-touching work via [Executor_pool] instead (PR #21530).

    Defense-in-depth: this wrapper converts that cryptic [Effect.Unhandled]
    into an actionable [Failure] naming the misuse and the alternative.  It
    only improves the surfaced error — the poison still happens in the inner
    [use_rw] frame before control returns here — so it diagnoses the bug
    faster, it does not prevent it. *)
let run_in_systhread f =
  match execution_context () with
  | Eio_fiber ->
    Eio_unix.run_in_systhread (fun () ->
      try f () with
      | Effect.Unhandled _ as exn ->
        failwith
          (Printf.sprintf
             "Eio_guard.run_in_systhread: body performed an unhandled effect (%s) on a \
              system thread, which has no Eio handler. Eio operations such as \
              Eio.Mutex.use_rw must not run here (use_rw poisons its mutex on the \
              resulting Effect.Unhandled). Offload Eio-touching work via Executor_pool \
              (e.g. Executor_pool_ref.submit_or_inline), not run_in_systhread."
             (Printexc.to_string exn)))
  | Non_eio -> f ()
;;

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

    Outside an Eio fiber, falls back to [Fun.protect]. *)
let protect ~finally body =
  match execution_context () with
  | Eio_fiber ->
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw finally;
      body ())
  | Non_eio -> Fun.protect ~finally body
;;

(** Cooperatively yield without raising if the Eio scheduler is unavailable. *)
let yield_if_ready () =
  match execution_context () with
  | Eio_fiber -> Eio.Fiber.yield ()
  | Non_eio -> ()
;;

let check_if_ready () =
  match execution_context () with Eio_fiber -> Eio.Fiber.check () | Non_eio -> ()
;;

let fair_yield = yield_if_ready
let default_fair_yield_interval = 1000

type yield_meter =
  { interval : int
  ; steps : int Atomic.t
  }

let create_yield_meter ?(interval = default_fair_yield_interval) () =
  { interval = max 1 interval; steps = Atomic.make 0 }
;;

let yield_step meter =
  let rec bump () =
    let current = Atomic.get meter.steps in
    let next = if current + 1 >= meter.interval then 0 else current + 1 in
    if Atomic.compare_and_set meter.steps current next then next = 0 else bump ()
  in
  if bump () then yield_if_ready ()
;;
