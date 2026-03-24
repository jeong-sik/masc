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
    ]
