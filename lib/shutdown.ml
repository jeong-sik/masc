(** Shutdown — Structured graceful shutdown with defined phases

    Phases execute in order:
    1. Notify  — Broadcast shutdown intent to connected clients
    2. Drain   — Wait for in-flight requests to complete (configurable timeout)
    3. Cleanup — Run registered hooks (cancel fibers, flush state, save checkpoint)
    4. Exit    — Terminate the Eio switch

    Each phase logs its start/end. If total shutdown exceeds force_timeout,
    the process is forcefully terminated.

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

let config_from_env () =
  let get_float name default =
    match Sys.getenv_opt name with
    | Some s -> Option.value ~default (float_of_string_opt s)
    | None -> default
  in
  {
    notify_delay_s = get_float "MASC_SHUTDOWN_NOTIFY_DELAY" 0.2;
    drain_timeout_s = get_float "MASC_SHUTDOWN_DRAIN_TIMEOUT" 5.0;
    cleanup_timeout_s = get_float "MASC_SHUTDOWN_CLEANUP_TIMEOUT" 3.0;
    force_timeout_s = get_float "MASC_SHUTDOWN_FORCE_TIMEOUT" 10.0;
  }

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

let create ?(config = config_from_env ()) () = {
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

let hooks : hook list ref = ref []

let register ~name ?(priority = 50) action =
  hooks := { name; priority; action } :: !hooks

let sorted_hooks () =
  List.sort (fun a b -> compare a.priority b.priority) !hooks

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
    Eio.Time.with_timeout_exn clock state.config.cleanup_timeout_s (fun () ->
      List.iter (fun hook ->
        try
          hook.action ();
          Log.Server.debug "[Shutdown] hook '%s' completed" hook.name
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.Server.warn "[Shutdown] hook '%s' failed: %s" hook.name (Printexc.to_string exn)
      ) all_hooks)
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

    (* INTENTIONAL: force-exit watchdog uses stdlib Thread, NOT Eio.Fiber.
       Runs outside the Eio domain so it can terminate the process even when
       Eio is deadlocked or stuck.  Cancelled via done_flag on normal exit. *)
    let done_flag = Atomic.make false in
    ignore (Thread.create (fun () ->
      Unix.sleepf state.config.force_timeout_s;
      if not (Atomic.get done_flag) then begin
        Log.Server.error "Shutdown exceeded %.0fs force timeout, forcing exit"
          state.config.force_timeout_s;
        exit 1
      end
    ) ());

    phase_notify state ~clock ~notify_fn;
    phase_drain state ~clock ~drain_check;
    phase_cleanup state ~clock;
    phase_exit state ~exit_fn;
    Atomic.set done_flag true
  end

(** {1 Queries} *)

let current_phase state = state.phase
let is_shutting_down state = state.phase <> Running && state.phase <> Done
let elapsed state =
  if state.started_at > 0.0 then Unix.gettimeofday () -. state.started_at
  else 0.0
