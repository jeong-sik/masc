(** Shutdown — Structured graceful shutdown with defined phases.

    Phases execute in order:
    1. Notify  — Broadcast shutdown intent to connected clients
    2. Drain   — Wait for in-flight requests to complete (configurable timeout)
    3. Cleanup — Run registered hooks (cancel fibers, flush state, save checkpoint)
    4. Exit    — Terminate the Eio switch

    The process entrypoint owns the hard [force_timeout_s] watchdog outside
    the Eio switch; phase execution never disarms its own supervisor.

    @since 2.102.0 *)

(** {1 Configuration} *)

type config = {
  notify_delay_s : float;
  drain_timeout_s : float;
  cleanup_timeout_s : float;
  force_timeout_s : float;
}

val default_config : config
val config_from_env : unit -> config

(** {1 Process deadline supervision} *)

type deadline_error =
  | Non_finite_deadline_timeout of float
  | Non_positive_deadline_timeout of float

val deadline_error_to_string : deadline_error -> string

type watchdog

val process_deadline_exit_code : int
(** Dedicated non-zero process status for a fired shutdown deadline. Process
    supervisors and runtime telemetry may use this SSOT to distinguish a hard
    deadline from generic exit status [1]. *)

type disarm_result =
  | Disarmed
  | Already_disarmed
  | Already_fired

val start_process_deadline_watchdog :
  timeout_s:float ->
  (watchdog, deadline_error) result
(** [start_process_deadline_watchdog] starts an OS-thread deadline authority.
    When the deadline fires, it terminates the process with failure status via
    {!Unix._exit}; no
    logging, channel flushing, [at_exit] callback, or runtime finalization can
    block the terminal action. It is
    is not attached to any Eio switch, so a failed switch, a fibre that ignores
    cooperative cancellation, or a stalled Eio domain cannot cancel its own
    process deadline. The process entrypoint must own the returned handle and
    disarm it only after the supervised switch has actually returned. *)

val disarm_deadline_watchdog : watchdog -> disarm_result
(** Atomically disarm an armed watchdog. The result distinguishes a successful
    disarm from an already-disarmed or already-fired watchdog. *)

val await_deadline_watchdog : watchdog -> unit
(** Join the watchdog thread. Intended for deterministic lifecycle tests and
    callers that need proof that the watchdog callback has finished. *)

(** {1 Phase Tracking} *)

type phase =
  | Running
  | Notifying
  | Draining
  | Cleaning
  | Exiting
  | Done

val phase_to_string : phase -> string

type state

val create : ?config:config -> unit -> state

(** {1 Hook Registry} *)

type hook = {
  name : string;
  priority : int;
  action : unit -> unit;
}

val register : name:string -> ?priority:int -> (unit -> unit) -> unit
val sorted_hooks : unit -> hook list
val run_registered_hooks : unit -> unit
(** Run every hook registered with {!register}, in priority order.

    This is the cleanup core used by {!initiate}'s cleanup phase and by the
    inline server shutdown path in {!Shutdown_hooks}. Hook exceptions are logged
    and swallowed except for [Eio.Cancel.Cancelled], which is re-raised. *)

(** {1 Global Shutdown Flag} *)

val is_shutting_down_global : unit -> bool

val mark_shutting_down : unit -> unit
(** Set the sticky global shutdown flag observed by
    [is_shutting_down_global]. Safe to call from an OCaml signal handler:
    backed by [Atomic.set], lock-free, async-signal-safe. Idempotent.

    Call this from the SIGTERM/SIGINT handler before any fiber observes
    [Eio.Cancel.Cancelled], so consumers can reclassify cancellation as
    graceful shutdown (see [Keeper_registry_types_failure.fiber_drop_cause]
    [Graceful_shutdown]). *)

(** {1 Phase Execution} *)

val initiate :
  state -> clock:'a Eio.Time.clock ->
  reason:string ->
  notify_fn:(string -> unit) ->
  drain_check:(unit -> bool) ->
  exit_fn:(unit -> unit) ->
  unit
(** Run the cooperative shutdown phases. This function deliberately does not
    own the hard process deadline: a caller supervising an Eio switch must
    start {!start_process_deadline_watchdog} outside that switch and disarm it
    only after the switch has actually returned. *)

(** {1 Queries} *)

val current_phase : state -> phase
val is_shutting_down : state -> bool
val elapsed : state -> float
