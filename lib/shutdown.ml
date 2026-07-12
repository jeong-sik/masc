(** Shutdown — Structured graceful shutdown with defined phases

    Phases execute in order:
    1. Notify  — Broadcast shutdown intent to connected clients
    2. Drain   — Wait for in-flight requests to complete (configurable timeout)
    3. Cleanup — Run registered hooks (cancel fibers, flush state, save checkpoint)
    4. Exit    — Terminate the Eio switch

    Each phase logs its start/end. The process entrypoint owns the hard
    [force_timeout_s] watchdog outside the Eio switch; phase execution never
    disarms its own supervisor.

    @since 2.102.0 *)

(** {1 Configuration} *)

type config = {
  notify_delay_s : float;   (** Time after notify before drain starts *)
  drain_timeout_s : float;  (** Max time to wait for in-flight work *)
  cleanup_timeout_s : float;(** Max time for cleanup hooks *)
  force_timeout_s : float;  (** Total max time before force exit *)
}

let default_config = {
  notify_delay_s = 0.2;
  drain_timeout_s = 5.0;
  cleanup_timeout_s = 3.0;
  force_timeout_s = 10.0;
}

type config_field =
  | Notify_delay
  | Drain_timeout
  | Cleanup_timeout
  | Force_timeout

let config_field_env_name = function
  | Notify_delay -> "MASC_SHUTDOWN_NOTIFY_DELAY"
  | Drain_timeout -> "MASC_SHUTDOWN_DRAIN_TIMEOUT"
  | Cleanup_timeout -> "MASC_SHUTDOWN_CLEANUP_TIMEOUT"
  | Force_timeout -> "MASC_SHUTDOWN_FORCE_TIMEOUT"

type config_error =
  | Invalid_config_number of { field : config_field; raw_value : string }
  | Non_finite_config_duration of { field : config_field; value : float }
  | Negative_config_duration of { field : config_field; value : float }
  | Non_positive_config_duration of { field : config_field; value : float }

let config_error_to_string = function
  | Invalid_config_number { field; raw_value } ->
      Printf.sprintf "%s must be a number (received %S)"
        (config_field_env_name field) raw_value
  | Non_finite_config_duration { field; value } ->
      Printf.sprintf "%s must be finite (received %g)"
        (config_field_env_name field) value
  | Negative_config_duration { field; value } ->
      Printf.sprintf "%s must be non-negative (received %g)"
        (config_field_env_name field) value
  | Non_positive_config_duration { field; value } ->
      Printf.sprintf "%s must be greater than zero (received %g)"
        (config_field_env_name field) value

let config_from_env_result () =
  let get_duration field ~default ~positive =
    match Sys.getenv_opt (config_field_env_name field) with
    | None -> Ok default
    | Some raw_value ->
        (match float_of_string_opt raw_value with
         | None -> Error (Invalid_config_number { field; raw_value })
         | Some value when not (Float.is_finite value) ->
             Error (Non_finite_config_duration { field; value })
         | Some value when positive && value <= 0.0 ->
             Error (Non_positive_config_duration { field; value })
         | Some value when value < 0.0 ->
             Error (Negative_config_duration { field; value })
         | Some value -> Ok value)
  in
  let ( let* ) = Result.bind in
  let* notify_delay_s =
    get_duration Notify_delay ~default:default_config.notify_delay_s
      ~positive:false
  in
  let* drain_timeout_s =
    get_duration Drain_timeout ~default:default_config.drain_timeout_s
      ~positive:false
  in
  let* cleanup_timeout_s =
    get_duration Cleanup_timeout ~default:default_config.cleanup_timeout_s
      ~positive:false
  in
  let* force_timeout_s =
    get_duration Force_timeout ~default:default_config.force_timeout_s
      ~positive:true
  in
  Ok { notify_delay_s; drain_timeout_s; cleanup_timeout_s; force_timeout_s }

let config_from_env () =
  match config_from_env_result () with
  | Ok config -> config
  | Error error -> invalid_arg (config_error_to_string error)
;;

(** {1 Process deadline supervision} *)

type deadline_error =
  | Non_finite_deadline_timeout of float
  | Non_positive_deadline_timeout of float
  | Watchdog_thread_start_failed of string

let deadline_error_to_string = function
  | Non_finite_deadline_timeout value ->
      Printf.sprintf "deadline timeout must be finite (received %g)" value
  | Non_positive_deadline_timeout value ->
      Printf.sprintf
        "deadline timeout must be greater than zero (received %g)"
        value
  | Watchdog_thread_start_failed reason ->
      Printf.sprintf "deadline watchdog thread failed to start: %s" reason

type watchdog_state =
  | Armed
  | Disarmed_state
  | Fired

type watchdog = {
  state : watchdog_state Atomic.t;
  thread : Thread.t;
}

type disarm_result =
  | Disarmed
  | Already_disarmed
  | Already_fired

let process_deadline_exit_code = 124
let process_deadline_start_failure_exit_code = 125

let start_process_deadline_watchdog ~timeout_s =
  if not (Float.is_finite timeout_s) then
    Error (Non_finite_deadline_timeout timeout_s)
  else if timeout_s <= 0.0 then
    Error (Non_positive_deadline_timeout timeout_s)
  else
    let state = Atomic.make Armed in
    (match
       try
         Ok
           (Thread.create
              (fun () ->
                try
                  Thread.delay timeout_s;
                  if Atomic.compare_and_set state Armed Fired then
                    Unix._exit process_deadline_exit_code
                with _ ->
                  if Atomic.compare_and_set state Armed Fired then
                    Unix._exit process_deadline_start_failure_exit_code)
              ())
       with exn -> Error (Watchdog_thread_start_failed (Printexc.to_string exn))
     with
     | Ok thread -> Ok { state; thread }
     | Error _ as error -> error)

let start_process_deadline_watchdog_or_exit ~timeout_s =
  match start_process_deadline_watchdog ~timeout_s with
  | Ok watchdog -> watchdog
  | Error _ -> Unix._exit process_deadline_start_failure_exit_code

let rec disarm_deadline_watchdog watchdog =
  if Atomic.compare_and_set watchdog.state Armed Disarmed_state then
    Disarmed
  else
    match Atomic.get watchdog.state with
    | Disarmed_state -> Already_disarmed
    | Fired -> Already_fired
    | Armed ->
        (* A concurrent timeout can only move [Armed] to [Fired]. Retry so the
           caller never receives an observation that contradicts the CAS. *)
        disarm_deadline_watchdog watchdog

let await_deadline_watchdog watchdog = Thread.join watchdog.thread

(** {1 Phase Tracking} *)

type phase =
  | Running
  | Notifying
  | Draining
  | Cleaning
  | Exiting
  | Done

let phase_to_string = function
  | Running -> "running"
  | Notifying -> "notifying"
  | Draining -> "draining"
  | Cleaning -> "cleaning"
  | Exiting -> "exiting"
  | Done -> "done"

type state = {
  mutable phase : phase;
  mutable started_at : float;
  mutable reason : string;
  entered : bool Atomic.t;
    (** CAS gate: ensures [initiate] runs phases at most once per state.
        Separate from the global [shutting_down_flag] which is a
        process-wide sticky observability flag. *)
  config : config;
}

let create ?config () =
  let config =
    match config with
    | Some config -> config
    | None -> config_from_env ()
  in
  {
    phase = Running;
    started_at = 0.0;
    reason = "";
    entered = Atomic.make false;
    config;
  }

(** {1 Hook Registry} *)

type hook = {
  name : string;
  priority : int;  (** Lower = runs first *)
  action : unit -> unit;
}

(** Global shutdown-started flag.  Set to [true] on the first [initiate]
    call.  This flag is sticky: it is never cleared, so it indicates that
    shutdown has started at least once, not that shutdown is currently in
    progress.  In production the process exits shortly after shutdown, so
    the sticky semantics are safe.  In tests where [exit_fn] is a no-op,
    callers must be aware that the flag stays [true]. *)
let shutting_down_flag = Atomic.make false

let is_shutting_down_global () = Atomic.get shutting_down_flag

(* Async-signal-safe marker. [Atomic.set] is lock-free, so it can be invoked
   from an OCaml signal handler. Idempotent; later calls are no-ops once the
   sticky flag is [true]. Wiring this from [bin/main_eio.ml]'s signal handler
   closes the gap where [Shutdown.initiate] is never called by the inline
   shutdown path, leaving [is_shutting_down_global] permanently [false] and
   making the keeper supervisor's graceful-shutdown branch unreachable. *)
let mark_shutting_down () = Atomic.set shutting_down_flag true

let hooks : hook list Atomic.t = Atomic.make []

let register ~name ?(priority = 50) action =
  let new_hook = { name; priority; action } in
  let rec loop () =
    let old = Atomic.get hooks in
    if not (Atomic.compare_and_set hooks old (new_hook :: old)) then loop ()
  in
  loop ()

let sorted_hooks () =
  let snapshot = Atomic.get hooks in
  List.sort (fun a b -> compare a.priority b.priority) snapshot

let run_registered_hooks () =
  let all_hooks = sorted_hooks () in
  List.iter
    (fun hook ->
      try
        hook.action ();
        Log.Server.debug "[Shutdown] hook '%s' completed" hook.name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.warn
          "[Shutdown] hook '%s' failed: %s"
          hook.name
          (Printexc.to_string exn))
    all_hooks

(** {1 Phase Execution} *)

(** Execute notify phase: broadcast shutdown to clients. *)
let phase_notify state ~clock ~notify_fn =
  state.phase <- Notifying;
  Log.Server.info "[Shutdown] Phase 1/4: NOTIFY (reason=%s)" state.reason;
  notify_fn state.reason;
  Eio.Time.sleep clock state.config.notify_delay_s

(** Execute drain phase: wait for in-flight work. *)
let phase_drain state ~clock ~drain_check =
  state.phase <- Draining;
  Log.Server.info "[Shutdown] Phase 2/4: DRAIN (timeout=%.1fs)" state.config.drain_timeout_s;
  let deadline = Eio.Time.now clock +. state.config.drain_timeout_s in
  let rec wait () =
    if drain_check () then
      Log.Server.info "[Shutdown] drain complete (all work finished)"
    else if Eio.Time.now clock >= deadline then
      Log.Server.warn "[Shutdown] drain timeout reached, proceeding"
    else begin
      Eio.Time.sleep clock 0.1;
      wait ()
    end
  in
  wait ()

(** Execute cleanup phase: run registered hooks with timeout. *)
let phase_cleanup state ~clock =
  state.phase <- Cleaning;
  let all_hooks = sorted_hooks () in
  Log.Server.info "[Shutdown] Phase 3/4: CLEANUP (%d hooks, timeout=%.1fs)"
    (List.length all_hooks) state.config.cleanup_timeout_s;
  (try
    Eio.Time.with_timeout_exn clock state.config.cleanup_timeout_s run_registered_hooks
  with Eio.Time.Timeout ->
    Log.Server.warn "[Shutdown] cleanup timeout (%.1fs) exceeded, proceeding"
      state.config.cleanup_timeout_s)

(** Execute exit phase. *)
let phase_exit state ~exit_fn =
  state.phase <- Exiting;
  let elapsed = Unix.gettimeofday () -. state.started_at in
  Log.Server.info "[Shutdown] Phase 4/4: EXIT (total=%.1fs)" elapsed;
  exit_fn ();
  state.phase <- Done

(** {1 Main Entry Point} *)

(** Initiate graceful shutdown.

    @param notify_fn Called with reason string to broadcast to clients
    @param drain_check Returns true when all in-flight work is complete
    @param exit_fn Called to terminate the process (e.g., Eio.Switch.fail) *)
let initiate state ~clock ~reason ~notify_fn ~drain_check ~exit_fn =
  (* CAS on per-state [entered] flag as the single-entry gate. The old
     code checked [state.phase <> Running] non-atomically, which races
     when two signals arrive in close succession (e.g. SIGTERM then
     SIGINT): both callers observe [Running] before either writes the
     new phase, both proceed, and the phases double-run with clobbered
     [started_at]/[reason]. Per-state CAS serializes entry at the CPU
     level without depending on the global [shutting_down_flag], which
     is documented as a sticky observability flag and must not gate
     repeated [initiate] calls on distinct [state]s (e.g. in tests). *)
  if not (Atomic.compare_and_set state.entered false true) then begin
    Log.Server.warn "[Shutdown] already in progress (phase=%s), ignoring"
      (phase_to_string state.phase);
  end else begin
    Atomic.set shutting_down_flag true;
    state.started_at <- Eio.Time.now clock;
    state.reason <- reason;
    Log.Server.info "[Shutdown] initiated: %s" reason;

    phase_notify state ~clock ~notify_fn;
    phase_drain state ~clock ~drain_check;
    phase_cleanup state ~clock;
    phase_exit state ~exit_fn
  end

(** {1 Queries} *)

let current_phase state = state.phase
let is_shutting_down state = state.phase <> Running && state.phase <> Done
let elapsed state =
  if state.started_at > 0.0 then Unix.gettimeofday () -. state.started_at
  else 0.0
