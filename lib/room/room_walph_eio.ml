(** Room_walph_eio: Eio-native Walph (Walph Wiggum variant) implementation

    Inspired by Geoffrey Huntley's Walph (Walph Wiggum variant) technique:
    @see https://ghuntley.com/ralph/

    Production-ready implementation using Eio concurrency primitives:
    - Eio.Mutex for thread-safe state access (fiber-friendly, non-blocking)
    - Eio.Condition for pause/resume (no busy-wait, proper fiber scheduling)
    - Fun.protect for exception safety (no zombie states)

    This module is designed to run inside Eio fiber context.
    For pure sync/testing, use Room.walph_* functions instead.

    @see Room for sync implementation (testing)
    @see mcp_server_eio for production usage
*)

(** {1 Types} *)

(** Walph (Walph Wiggum variant) state with Eio concurrency primitives *)
type walph_state = {
  mutable running : bool;
  mutable paused : bool;
  mutable stop_requested : bool;
  mutable current_preset : string;
  mutable iterations : int;
  mutable completed : int;
  mutable claimed : int;
  mutable released_on_error : int;
  mutable errors : int;
  mutable consecutive_errors : int;
  mutable max_consecutive_errors : int;
  mutable error_backoff_sec : int;
  mutable last_error : string option;
  mutable last_task_id : string option;
  mutable started_at : string option;
  mutable last_stop_reason : string option;
  mutex : Eio.Mutex.t;        (** Eio-native mutex (fiber-friendly) *)
  cond : Eio.Condition.t;     (** Eio-native condition variable *)
}

(** {1 State Management} *)

(** Global Walph state table with Eio mutex for thread-safe access *)
let walph_states : (string, walph_state) Hashtbl.t = Hashtbl.create 16
let walph_states_mutex = Eio.Mutex.create ()

(** Escape colon in agent_name to prevent key collision.
    "agent:foo" -> "agent::foo" (double colon as escape)
    Key format: "room||agent" using || as separator (unlikely in paths/names) *)
let escape_agent_name name =
  (* Replace | with || to escape, then use | as separator *)
  let buf = Buffer.create (String.length name) in
  String.iter (fun c ->
    if c = '|' then Buffer.add_string buf "||"
    else Buffer.add_char buf c
  ) name;
  Buffer.contents buf

(** Generate state key: room||agent for independent Walph per agent
    Uses || separator to avoid collision with : in paths *)
let make_walph_key config ~agent_name =
  if agent_name = "" then
    Error "Walph: agent_name cannot be empty"
  else
    Ok (Printf.sprintf "%s||%s" config.Room_utils.base_path (escape_agent_name agent_name))

(** Get or create Walph state for a specific agent (thread-safe)
    Each agent has independent Walph state, enabling parallel loops *)
let get_walph_state config ~agent_name =
  match make_walph_key config ~agent_name with
  | Error msg -> Error msg
  | Ok key ->
      Ok (Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
        match Hashtbl.find_opt walph_states key with
        | Some s -> s
        | None ->
            let s = {
              running = false; paused = false; stop_requested = false;
              current_preset = ""; iterations = 0; completed = 0;
              claimed = 0; released_on_error = 0; errors = 0; consecutive_errors = 0;
              max_consecutive_errors = 5; error_backoff_sec = 2;
              last_error = None; last_task_id = None; started_at = None; last_stop_reason = None;
              mutex = Eio.Mutex.create ();
              cond = Eio.Condition.create ();
            } in
            Hashtbl.replace walph_states key s;
            s
      ))

(** Get or create Walph state, raising on error. For test convenience.
    @raise Invalid_argument if agent_name is empty *)
let get_walph_state_exn config ~agent_name =
  match get_walph_state config ~agent_name with
  | Ok s -> s
  | Error msg -> invalid_arg msg

(** Remove Walph state for an agent (cleanup to prevent memory leak)
    @return Error if Walph is still running (zombie prevention), Ok () otherwise *)
let remove_walph_state config ~agent_name =
  match make_walph_key config ~agent_name with
  | Error msg -> Error msg
  | Ok key ->
      Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
        match Hashtbl.find_opt walph_states key with
        | None -> Ok ()  (* Already removed, no-op *)
        | Some state ->
            if state.running then
              Error (Printf.sprintf "Walph: cannot remove state for %s while running. Call STOP first." agent_name)
            else begin
              Hashtbl.remove walph_states key;
              Ok ()
            end
      )

(** List all active Walph states in a room (for swarm coordination)
    Uses || as separator to match make_walph_key *)
let list_walph_states config =
  let prefix = config.Room_utils.base_path ^ "||" in
  let prefix_len = String.length prefix in
  Eio.Mutex.use_rw ~protect:true walph_states_mutex (fun () ->
    Hashtbl.fold (fun key state acc ->
      if String.length key > prefix_len &&
         String.sub key 0 prefix_len = prefix then
        (* Extract agent name (still escaped, but usable as identifier) *)
        let agent = String.sub key prefix_len (String.length key - prefix_len) in
        (agent, state) :: acc
      else acc
    ) walph_states []
  )

(** Run function with Walph state mutex locked (Eio-native) *)
let with_walph_lock state f =
  Eio.Mutex.use_rw ~protect:true state.mutex f

(** JSON status payload for a single walph agent. *)
let walph_status_json config ~agent_name =
  match get_walph_state config ~agent_name with
  | Error msg ->
      `Assoc [
        ("ok", `Bool false);
        ("agent", `String agent_name);
        ("error", `String msg);
      ]
  | Ok state ->
      with_walph_lock state (fun () ->
        `Assoc [
          ("ok", `Bool true);
          ("agent", `String agent_name);
          ("running", `Bool state.running);
          ("paused", `Bool state.paused);
          ("stop_requested", `Bool state.stop_requested);
          ("preset", `String state.current_preset);
          ("iterations", `Int state.iterations);
          ("claimed", `Int state.claimed);
          ("completed", `Int state.completed);
          ("released_on_error", `Int state.released_on_error);
          ("errors", `Int state.errors);
          ("consecutive_errors", `Int state.consecutive_errors);
          ("max_consecutive_errors", `Int state.max_consecutive_errors);
          ("error_backoff_sec", `Int state.error_backoff_sec);
          ("last_task_id", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_task_id);
          ("last_error", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_error);
          ("started_at", Option.fold ~none:`Null ~some:(fun s -> `String s) state.started_at);
          ("last_stop_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) state.last_stop_reason);
        ]
      )

(** {1 Control Commands} *)

(** Handle @walph control command (Eio-native, fiber-safe)
    @param config Room configuration
    @param from_agent Agent sending the command (controls own Walph)
    @param command Command (STOP, PAUSE, RESUME, STATUS)
    @param args Command arguments
    @param target_agent Optional: control another agent's Walph (default: self)
    @return Response message *)
let walph_control config ~from_agent ~command ~args ?(target_agent=None) () =
  let agent_name = match target_agent with Some a -> a | None -> from_agent in
  match get_walph_state config ~agent_name with
  | Error msg -> msg
  | Ok state ->
  let response = with_walph_lock state (fun () ->
    match command with
    | "STOP" ->
        if state.running then begin
          state.stop_requested <- true;
          Eio.Condition.broadcast state.cond;  (* Wake up paused fibers *)
          Printf.sprintf "🛑 @walph STOP requested by %s (will stop after current iteration)" from_agent
        end else
          "ℹ️ @walph is not currently running"
    | "PAUSE" ->
        if state.running && not state.paused then begin
          state.paused <- true;
          Printf.sprintf "⏸️ @walph PAUSED by %s (use @walph RESUME to continue)" from_agent
        end else if state.paused then
          "ℹ️ @walph is already paused"
        else
          "ℹ️ @walph is not currently running"
    | "RESUME" ->
        if state.paused then begin
          state.paused <- false;
          Eio.Condition.broadcast state.cond;  (* Wake up paused fibers *)
          Printf.sprintf "▶️ @walph RESUMED by %s" from_agent
        end else if state.running then
          "ℹ️ @walph is already running"
        else
          "ℹ️ @walph is not currently running"
    | "STATUS" ->
        if state.running then
          Printf.sprintf
            "📊 @walph STATUS: %s (iter: %d, claimed: %d, done: %d, released: %d, errs: %d/%d, paused: %b)"
            state.current_preset state.iterations state.claimed state.completed
            state.released_on_error state.consecutive_errors state.max_consecutive_errors state.paused
        else
          "ℹ️ @walph loop is removed; status remains for transition-only inspection"
    | "START" ->
        let args_suffix =
          let trimmed = String.trim args in
          if String.equal trimmed "" then "" else Printf.sprintf " (%s)" trimmed
        in
        Printf.sprintf "🚫 @walph START is disabled; walph loop has been removed%s" args_suffix
    | _ ->
        Printf.sprintf "❓ Unknown @walph command: %s. Valid: START, STOP, PAUSE, RESUME, STATUS" command
  ) in
  (* Broadcast the response *)
  let _ = Room_state.broadcast config ~from_agent:"walph" ~content:response in
  response

(** {1 Legacy Loop Stub} *)

(** Walph loop execution has been removed.
    Keep a stub for transitional direct callers so they get a clear, non-mutating response. *)
let walph_loop config ~clock:_ ~agent_name
    ?(preset="drain") ?(max_iterations=10) ?target
    ?(max_consecutive_errors=5) ?(error_backoff_sec=2)
    ?(default_model="explicit-model-required")
    ~model_dispatch:_ () =
  Room_utils_ops.ensure_initialized config;
  let _ = get_walph_state_exn config ~agent_name in
  let details =
    [
      ("preset", `String preset);
      ("max_iterations", `Int max_iterations);
      ( "target",
        match target with
        | Some value -> `String value
        | None -> `Null );
      ("max_consecutive_errors", `Int max_consecutive_errors);
      ("error_backoff_sec", `Int error_backoff_sec);
      ("default_model", `String default_model);
      ("ts", `String (Types.now_iso ()));
    ]
  in
  Room_utils_ops.log_event config
    (Yojson.Safe.to_string
       (`Assoc
         (("type", `String "walph_loop_removed_call")
          :: ("agent", `String agent_name)
          :: details)));
  let result =
    "🚫 Walph loop has been removed. Use Team Session + Supervisor for supervised swarm execution."
  in
  let _ = Room_state.broadcast config ~from_agent:"walph" ~content:result in
  result

(** {1 Swarm Walph - Multi-Agent Coordination} *)

(** Swarm status summary for all active Walph instances in a room *)
type swarm_status = {
  total_agents: int;
  running_count: int;
  paused_count: int;
  completed_tasks: int;
  total_iterations: int;
  agents: (string * walph_state) list;
}

(** Get comprehensive swarm status across all Walph instances
    @param config Room configuration
    @return Swarm status summary *)
let swarm_walph_status config =
  let agents = list_walph_states config in
  let running = List.filter (fun (_, s) -> s.running) agents in
  let paused = List.filter (fun (_, s) -> s.paused) agents in
  let total_completed = List.fold_left (fun acc (_, s) -> acc + s.completed) 0 agents in
  let total_iters = List.fold_left (fun acc (_, s) -> acc + s.iterations) 0 agents in
  {
    total_agents = List.length agents;
    running_count = List.length running;
    paused_count = List.length paused;
    completed_tasks = total_completed;
    total_iterations = total_iters;
    agents;
  }

(** Format swarm status for display *)
let format_swarm_status status =
  let agent_lines = List.map (fun (name, s) ->
    Printf.sprintf "  • %s: %s (iter: %d, done: %d)%s"
      name
      (if s.running then (if s.paused then "⏸️ PAUSED" else "🔄 RUNNING") else "⚪ IDLE")
      s.iterations s.completed
      (if s.running then " [" ^ s.current_preset ^ "]" else "")
  ) status.agents in
  Printf.sprintf
    "🐝 **Swarm Walph Status**\n\
     ├─ Agents: %d total, %d running, %d paused\n\
     ├─ Tasks completed: %d\n\
     ├─ Total iterations: %d\n\
     └─ Details:\n%s"
    status.total_agents status.running_count status.paused_count
    status.completed_tasks status.total_iterations
    (if agent_lines = [] then "  (no agents)" else String.concat "\n" agent_lines)

(** Stop all running Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the stop command
    @return Summary of stopped instances *)
let swarm_walph_stop config ~from_agent =
  let agents = list_walph_states config in
  let running_agents = List.filter (fun (_, s) -> s.running) agents in

  if running_agents = [] then
    "ℹ️ No running Walph instances to stop"
  else begin
    let stopped = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.running then begin
          state.stop_requested <- true;
          Eio.Condition.broadcast state.cond;
          agent_name
        end else ""
      )
    ) running_agents in

    let stopped_list = List.filter ((<>) "") stopped in
    let _ = Room_state.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "🛑 SWARM STOP by %s: %d agents signaled" from_agent (List.length stopped_list)) in

    Printf.sprintf "🛑 Swarm stop requested for %d agents: %s"
      (List.length stopped_list)
      (String.concat ", " stopped_list)
  end

(** Pause all running Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the pause command
    @return Summary of paused instances *)
let swarm_walph_pause config ~from_agent =
  let agents = list_walph_states config in
  let running_agents = List.filter (fun (_, s) -> s.running && not s.paused) agents in

  if running_agents = [] then
    "ℹ️ No running (un-paused) Walph instances to pause"
  else begin
    let paused = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.running && not state.paused then begin
          state.paused <- true;
          agent_name
        end else ""
      )
    ) running_agents in

    let paused_list = List.filter ((<>) "") paused in
    let _ = Room_state.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "⏸️ SWARM PAUSE by %s: %d agents paused" from_agent (List.length paused_list)) in

    Printf.sprintf "⏸️ Swarm pause applied to %d agents: %s"
      (List.length paused_list)
      (String.concat ", " paused_list)
  end

(** Resume all paused Walph instances in a swarm
    @param config Room configuration
    @param from_agent Agent issuing the resume command
    @return Summary of resumed instances *)
let swarm_walph_resume config ~from_agent =
  let agents = list_walph_states config in
  let paused_agents = List.filter (fun (_, s) -> s.paused) agents in

  if paused_agents = [] then
    "ℹ️ No paused Walph instances to resume"
  else begin
    let resumed = List.map (fun (agent_name, state) ->
      with_walph_lock state (fun () ->
        if state.paused then begin
          state.paused <- false;
          Eio.Condition.broadcast state.cond;
          agent_name
        end else ""
      )
    ) paused_agents in

    let resumed_list = List.filter ((<>) "") resumed in
    let _ = Room_state.broadcast config ~from_agent:"walph-swarm"
      ~content:(Printf.sprintf "▶️ SWARM RESUME by %s: %d agents resumed" from_agent (List.length resumed_list)) in

    Printf.sprintf "▶️ Swarm resume applied to %d agents: %s"
      (List.length resumed_list)
      (String.concat ", " resumed_list)
  end

(** Command pattern for swarm control *)
let swarm_walph_control config ~from_agent ~command () =
  match String.uppercase_ascii command with
  | "STATUS" ->
      let status = swarm_walph_status config in
      let formatted = format_swarm_status status in
      let _ = Room_state.broadcast config ~from_agent:"walph-swarm" ~content:formatted in
      formatted
  | "STOP" ->
      swarm_walph_stop config ~from_agent
  | "PAUSE" ->
      swarm_walph_pause config ~from_agent
  | "RESUME" ->
      swarm_walph_resume config ~from_agent
  | cmd ->
      Printf.sprintf "❓ Unknown swarm command: %s. Valid: STATUS, STOP, PAUSE, RESUME" cmd
