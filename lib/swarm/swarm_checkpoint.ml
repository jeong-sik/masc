(** Swarm Checkpoint - Swarm-level state persistence.

    Saves and restores the full swarm state (agents, tasks, operations,
    progress) so a server restart does not lose coordination context.

    Persistence target: .masc/swarm-checkpoint.json (filesystem).

    @since 2.80.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type agent_snapshot = {
  name : string;
  agent_type : string;
  status : string;
  current_task : string option;
  last_seen : string;
}
[@@deriving yojson]

type task_snapshot = {
  id : string;
  title : string;
  status : string;
  assigned_to : string option;
  priority : int;
}
[@@deriving yojson]

type operation_snapshot = {
  operation_id : string;
  objective : string;
  status : string;
  created_at : string;
}
[@@deriving yojson]

type goal_progress = {
  goal_id : string;
  title : string;
  metric_current : float option;
  metric_target : float option;
  completion_pct : float;
}
[@@deriving yojson]

type swarm_snapshot = {
  version : int;
  saved_at : string;
  room_id : string;
  agents : agent_snapshot list;
  tasks : task_snapshot list;
  operations : operation_snapshot list;
  goals : goal_progress list;
  total_tasks : int;
  done_tasks : int;
  active_agents : int;
}
[@@deriving yojson]

(* ================================================================ *)
(* Snapshot construction                                            *)
(* ================================================================ *)

let checkpoint_filename = "swarm-checkpoint.json"

let checkpoint_path (config : Coord.config) =
  Filename.concat config.base_path
    (Filename.concat ".masc" checkpoint_filename)

let agent_to_snapshot (agent : Types.agent) : agent_snapshot =
  {
    name = agent.name;
    agent_type = agent.agent_type;
    status = Types.agent_status_to_string agent.status;
    current_task = agent.current_task;
    last_seen = agent.last_seen;
  }

let task_to_snapshot (task : Types.task) : task_snapshot =
  {
    id = task.id;
    title = task.title;
    status = Types.task_status_to_string task.task_status;
    assigned_to =
      (match task.task_status with
       | Types.Claimed { assignee; _ } -> Some assignee
       | Types.InProgress { assignee; _ } -> Some assignee
       | _ -> None);
    priority = task.priority;
  }

let build_snapshot (config : Coord.config) : swarm_snapshot =
  let room_id = "default" in
  let agents = Coord.get_agents_raw config in
  let backlog = Coord.read_backlog config in
  let tasks = backlog.tasks in
  let agent_snapshots = List.map agent_to_snapshot agents in
  let task_snapshots = List.map task_to_snapshot tasks in
  let total = List.length tasks in
  let done_count =
    List.length
      (List.filter
         (fun (t : Types.task) ->
           match t.task_status with Types.Done _ -> true | _ -> false)
         tasks)
  in
  let active =
    List.length
      (List.filter
         (fun (a : Types.agent) ->
           match a.status with Types.Active -> true | _ -> false)
         agents)
  in
  {
    version = 1;
    saved_at = Types.now_iso ();
    room_id;
    agents = agent_snapshots;
    tasks = task_snapshots;
    operations = [];
    goals = [];
    total_tasks = total;
    done_tasks = done_count;
    active_agents = active;
  }

(* ================================================================ *)
(* Save / Restore                                                   *)
(* ================================================================ *)

let save config =
  let snapshot = build_snapshot config in
  let json = swarm_snapshot_to_yojson snapshot in
  let path = checkpoint_path config in
  Coord_utils.write_json_local path json;
  Ok snapshot

let restore config : (swarm_snapshot, string) result =
  let path = checkpoint_path config in
  if not (Sys.file_exists path) then
    Error "No swarm checkpoint found"
  else
    match Safe_ops.read_json_file_safe path with
    | Ok json ->
        (match swarm_snapshot_of_yojson json with
         | Ok snap -> Ok snap
         | Error e -> Error (Printf.sprintf "Checkpoint parse error: %s" e))
    | Error e -> Error (Printf.sprintf "Checkpoint read error: %s" e)

(* ================================================================ *)
(* Periodic save daemon (Eio fiber)                                 *)
(* ================================================================ *)

let periodic_save_daemon ~sw ~clock config ~interval_sec =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock (Float.of_int interval_sec);
      (match save config with
       | Ok snap ->
           Log.Coord.info "Swarm checkpoint saved: %d agents, %d/%d tasks done"
             snap.active_agents snap.done_tasks snap.total_tasks
       | Error e ->
           Log.Swarm.error "save error: %s" e);
      loop ()
    in
    (try loop ()
     with
     | Eio.Cancel.Cancelled _ -> `Stop_daemon
     | End_of_file -> `Stop_daemon))

(* ================================================================ *)
(* JSON response helpers                                            *)
(* ================================================================ *)

let snapshot_summary_json snap =
  `Assoc [
    ("status", `String "ok");
    ("saved_at", `String snap.saved_at);
    ("room_id", `String snap.room_id);
    ("active_agents", `Int snap.active_agents);
    ("total_tasks", `Int snap.total_tasks);
    ("done_tasks", `Int snap.done_tasks);
    ("completion_pct",
     `Float
       (if snap.total_tasks = 0 then 0.0
        else Float.of_int snap.done_tasks /. Float.of_int snap.total_tasks *. 100.0));
    ("agents", `List (List.map agent_snapshot_to_yojson snap.agents));
    ("tasks", `List (List.map task_snapshot_to_yojson snap.tasks));
  ]
