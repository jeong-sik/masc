(** MASC Tempo Control - Dynamic Orchestrator Interval

    Cluster tempo control for adaptive orchestration:
    - Urgent tasks (priority 1-2) → Fast tempo (60s)
    - Normal tasks (priority 3) → Normal tempo (300s)
    - Idle (no tasks) → Slow tempo (600s)

    Storage: .masc/tempo.json
*)

(** Tempo configuration *)
type tempo_config = {
  min_interval_s: float;      (* Minimum interval (fast tempo) *)
  max_interval_s: float;      (* Maximum interval (slow tempo) *)
  default_interval_s: float;  (* Default interval *)
  adaptive: bool;             (* Enable adaptive tempo *)
}

(** Current tempo state *)
type tempo_state = {
  current_interval_s: float;
  last_adjusted: float;
  reason: string;
}

(** Default configuration - from Env_config *)
let default_config = {
  min_interval_s = Env_config.Tempo.min_interval_seconds;
  max_interval_s = Env_config.Tempo.max_interval_seconds;
  default_interval_s = Env_config.Tempo.default_interval_seconds;
  adaptive = true;
}

(** Get tempo file path *)
let tempo_file (config : Workspace_utils.config) =
  Filename.concat (Workspace_utils.masc_dir config) "tempo.json"

(** State to JSON *)
let state_to_json (state : tempo_state) : Yojson.Safe.t =
  `Assoc [
    ("current_interval_s", `Float state.current_interval_s);
    ("last_adjusted", `Float state.last_adjusted);
    ("reason", `String state.reason);
  ]

(** State from JSON *)
let state_of_json (json : Yojson.Safe.t) : tempo_state option =
  let current_interval_s = Json_util.get_float json "current_interval_s" in
  let last_adjusted = Json_util.get_float json "last_adjusted" in
  let reason = Json_util.get_string json "reason" in
  match current_interval_s, last_adjusted, reason with
  | Some current_interval_s, Some last_adjusted, Some reason ->
    Some { current_interval_s; last_adjusted; reason }
  | _ -> None

(** Load current tempo state *)
let load_state (config : Workspace_utils.config) : tempo_state =
  let default_state = { current_interval_s = default_config.default_interval_s;
                        last_adjusted = 0.0; reason = "default" } in
  let path = tempo_file config in
  if Sys.file_exists path then
    match Safe_ops.read_json_file_safe path with
    | Ok json ->
      (match state_of_json json with Some state -> state | None -> default_state)
    | Error e ->
        Log.Workspace.debug "tempo: state load failed (%s): %s" path e;
        default_state
  else
    { current_interval_s = default_config.default_interval_s;
      last_adjusted = 0.0;
      reason = "default" }

(** Save tempo state *)
let save_state (config : Workspace_utils.config) (state : tempo_state) : unit =
  let path = tempo_file config in
  let masc_dir = Workspace_utils.masc_dir config in
  Fs_compat.mkdir_p masc_dir;
  let json = state_to_json state in
  let content = Yojson.Safe.pretty_to_string json in
  Fs_compat.save_file path content

(** Set tempo manually *)
let set_tempo (config : Workspace_utils.config) ~interval_s ~reason : tempo_state =
  let clamped =
    max default_config.min_interval_s
      (min default_config.max_interval_s interval_s)
  in
  let state = {
    current_interval_s = clamped;
    last_adjusted = Time_compat.now ();
    reason;
  } in
  save_state config state;
  state

(** Get current tempo *)
let get_tempo (config : Workspace_utils.config) : tempo_state =
  load_state config

let is_pending_task (task : Masc_domain.task) : bool =
  not (Masc_domain.task_status_is_terminal task.task_status)

(** Calculate adaptive tempo based on task urgency *)
let calculate_adaptive_tempo (tasks : Masc_domain.task list) : float * string =
  if tasks = [] then
    (default_config.max_interval_s, "idle - no pending tasks")
  else
    let urgent_count = List.filter (fun t -> t.Masc_domain.priority <= 2) tasks |> List.length in
    let high_count = List.filter (fun t -> t.Masc_domain.priority = 3) tasks |> List.length in
    if urgent_count > 0 then
      (default_config.min_interval_s,
       Printf.sprintf "fast - %d urgent task(s)" urgent_count)
    else if high_count > 0 then
      (default_config.default_interval_s,
       Printf.sprintf "normal - %d pending task(s)" high_count)
    else
      (default_config.max_interval_s,
       Printf.sprintf "slow - %d low priority task(s)" (List.length tasks))

(** Adjust tempo adaptively based on current tasks *)
let adjust_tempo (config : Workspace_utils.config) : tempo_state =
  let tasks = Workspace.get_tasks_raw config in
  let pending = List.filter is_pending_task tasks in
  let (interval, reason) = calculate_adaptive_tempo pending in
  let state = set_tempo config ~interval_s:interval ~reason in
  state

(** Format tempo state for display *)
let format_state (state : tempo_state) : string =
  let interval_str =
    if state.current_interval_s < 120.0 then
      Printf.sprintf "%.0fs" state.current_interval_s
    else
      Printf.sprintf "%.1fm" (state.current_interval_s /. 60.0)
  in
  let age =
    let elapsed = Time_compat.now () -. state.last_adjusted in
    if elapsed < 60.0 then "just now"
    else if elapsed < Masc_time_constants.hour then Printf.sprintf "%.0fm ago" (elapsed /. 60.0)
    else Printf.sprintf "%.1fh ago" (elapsed /. Masc_time_constants.hour)
  in
  Printf.sprintf "⏱️ Tempo: %s (%s, adjusted %s)" interval_str state.reason age

(** Reset tempo to default *)
let reset_tempo (config : Workspace_utils.config) : tempo_state =
  set_tempo config
    ~interval_s:default_config.default_interval_s
    ~reason:"reset to default"
