type phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

type t = {
  phase : phase;
  state_ready : bool;
  backend_mode : string;
  pending_lazy_tasks : string list;
  last_error : string option;
  fallback_reason : string option;
  path_diagnostics : Yojson.Safe.t option;
  config_resolution : Yojson.Safe.t option;
  started_at : float;
}

let state =
  ref
    {
      phase = Blocking;
      state_ready = false;
      backend_mode = "unknown";
      pending_lazy_tasks = [];
      last_error = None;
      fallback_reason = None;
      path_diagnostics = None;
      config_resolution = None;
      started_at = Unix.gettimeofday ();
    }

let phase_to_string = function
  | Blocking -> "blocking"
  | Lazy -> "lazy"
  | Ready -> "ready"
  | Degraded -> "degraded"

let update f = state := f !state

let reset ?(backend_mode = "unknown") () =
  state :=
    {
      phase = Blocking;
      state_ready = false;
      backend_mode;
      pending_lazy_tasks = [];
      last_error = None;
      fallback_reason = None;
      path_diagnostics = None;
      config_resolution = None;
      started_at = Unix.gettimeofday ();
    }

let mark_blocking ~backend_mode =
  update (fun current ->
      {
        current with
        phase = Blocking;
        state_ready = false;
        backend_mode;
        pending_lazy_tasks = [];
        last_error = None;
      })

(** True when the HTTP accept loop can serve requests (always true after socket bind). *)
let is_live () = true

(** Seconds elapsed since startup began. *)
let elapsed_since_start () =
  Unix.gettimeofday () -. !state.started_at

(** Default startup watchdog timeout in seconds. Override with MASC_STARTUP_WATCHDOG_SEC.
    Raised from 120 to 240 to accommodate PG cold-start + keeper bootstrap delays. *)
let default_watchdog_timeout_sec = 240.0

(** Read watchdog timeout from env, clamped to [30, 600]. *)
let watchdog_timeout_sec () = Env_config.Transport.startup_watchdog_sec ()

let mark_state_ready ~backend_mode =
  update (fun current ->
      { current with phase = Ready; state_ready = true; backend_mode })

let note_fallback reason =
  update (fun current -> { current with fallback_reason = Some reason })

let activate_lazy ~backend_mode ~tasks =
  update (fun current ->
      if tasks = [] then
        { current with phase = Ready; state_ready = true; backend_mode }
      else
        {
          current with
          phase = Lazy;
          state_ready = true;
          backend_mode;
          pending_lazy_tasks = tasks;
        })

let pending_lazy_tasks () =
  !state.pending_lazy_tasks

let lazy_tasks_complete () =
  !state.pending_lazy_tasks = []

let finish_lazy_task ~task =
  update (fun current ->
      let pending_lazy_tasks =
        List.filter (fun candidate -> candidate <> task) current.pending_lazy_tasks
      in
      let phase =
        match (current.phase, pending_lazy_tasks) with
        | Degraded, _ -> Degraded
        | _, [] -> Ready
        | _ -> Lazy
      in
      { current with phase; pending_lazy_tasks })

let fail_lazy_task ~task ~error =
  update (fun current ->
      let pending_lazy_tasks =
        List.filter (fun candidate -> candidate <> task) current.pending_lazy_tasks
      in
      {
        current with
        phase = Degraded;
        state_ready = true;
        pending_lazy_tasks;
        last_error = Some error;
      })

let mark_degraded ~error =
  update (fun current -> { current with phase = Degraded; last_error = Some error })

let note_runtime_resolution ~path_diagnostics ~config_resolution =
  update (fun current ->
      { current with path_diagnostics = Some path_diagnostics; config_resolution = Some config_resolution })

let to_yojson () =
  let current = !state in
  `Assoc
    [
      ("phase", `String (phase_to_string current.phase));
      ("state_ready", `Bool current.state_ready);
      ("backend_mode", `String current.backend_mode);
      ( "pending_lazy_tasks",
        `List (List.map (fun task -> `String task) current.pending_lazy_tasks) );
      ( "last_error",
        match current.last_error with
        | Some error -> `String error
        | None -> `Null );
      ( "fallback_reason",
        match current.fallback_reason with
        | Some reason -> `String reason
        | None -> `Null );
      ( "path_diagnostics",
        match current.path_diagnostics with
        | Some value -> value
        | None -> `Null );
      ( "config_resolution",
        match current.config_resolution with
        | Some value -> value
        | None -> `Null );
      ("elapsed_sec", `Float (elapsed_since_start ()));
      ("watchdog_timeout_sec", `Float (watchdog_timeout_sec ()));
    ]
