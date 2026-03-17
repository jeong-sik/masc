(** MASC Dashboard - Terminal-based Status Visualization

    Usage:
    - MCP: masc_dashboard
    - CLI: masc dashboard | watch -n 1 masc dashboard

    Shows:
    - Active agents (with zombie detection)
    - Task board (by status)
    - File locks
    - Recent broadcasts
    - Tempo status
    - Active worktrees
*)

(* ===== Constants ===== *)

(** Maximum path length before truncation *)
let max_path_length = 30

(** Maximum message content length before truncation *)
let max_message_length = 35

(** Maximum pending tasks to show *)
let max_pending_tasks = 5

(** Maximum recent messages to show *)
let max_recent_messages = 5

(** Minimum section border length *)
let min_border_length = 45

(* ===== Types ===== *)

(** Dashboard section *)
type section = {
  title: string;
  content: string list;
  empty_msg: string;
}

type scope =
  | All
  | Current

type room_snapshot = {
  room_id: string;
  is_current: bool;
  agents: Types.agent list;
  tasks: Types.task list;
  messages: Types.message list;
  locks: int;
}

type swarm_lane_summary = {
  label: string;
  present: bool;
  phase: string;
  motion_state: string;
  age: string;
  current_step: string;
  hard_flags: string list;
}

(** Format a section *)
let format_section (s : section) : string =
  let header = Printf.sprintf "== %s ==" s.title in
  let border_len = max min_border_length (String.length header + 4) in
  let top_border = header ^ String.make (border_len - String.length header) '=' in
  let bottom_border = String.make border_len '-' in
  let content =
    if List.length s.content = 0 then
      [Printf.sprintf "  %s" s.empty_msg]
    else
      List.map (fun line ->
        Printf.sprintf "  %s" line
      ) s.content
  in
  String.concat "\n" ([top_border] @ content @ [bottom_border])

(** Parse ISO timestamp to Unix time (UTC) *)
let parse_iso_timestamp (s : string) : float option =
  (* Format: 2025-01-09T12:00:00Z or 2025-01-09T12:00:00.123Z *)
  try
    let open Scanf in
    sscanf s "%d-%d-%dT%d:%d:%d" (fun y m d h min sec ->
      let tm = {
        Unix.tm_sec = sec; tm_min = min; tm_hour = h;
        tm_mday = d; tm_mon = m - 1; tm_year = y - 1900;
        tm_wday = 0; tm_yday = 0; tm_isdst = false
      } in
      (* Unix.mktime interprets tm as local time, but ISO 8601 'Z' means UTC.
         Adjust: local_t is too small by tz_offset, so add it back.
         tz_offset = local_t - mktime(gmtime(local_t)) = seconds east of UTC. *)
      let (local_t, _) = Unix.mktime tm in
      let utc_tm = Unix.gmtime local_t in
      let (utc_as_local, _) = Unix.mktime utc_tm in
      let tz_offset = local_t -. utc_as_local in
      Some (local_t +. tz_offset)
    )
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

let format_elapsed now timestamp fallback =
  match parse_iso_timestamp timestamp with
  | Some ts ->
      let elapsed = now -. ts in
      if elapsed < 60.0 then Printf.sprintf "%.0fs ago" elapsed
      else if elapsed < 3600.0 then Printf.sprintf "%.0fm ago" (elapsed /. 60.0)
      else Printf.sprintf "%.1fh ago" (elapsed /. 3600.0)
  | None -> fallback

let truncate_path (path : string) : string =
  if String.length path > max_path_length then
    let suffix_len = max_path_length - 3 in
    "..." ^ String.sub path (String.length path - suffix_len) suffix_len
  else path

let truncate_message (msg : string) : string =
  if String.length msg > max_message_length then
    let prefix_len = max_message_length - 3 in
    String.sub msg 0 prefix_len ^ "..."
  else msg

let agent_lines now (agents : Types.agent list) =
  List.map (fun (agent : Types.agent) ->
    let status_str = Types.agent_status_to_string agent.status in
    let elapsed_str = format_elapsed now agent.last_seen agent.last_seen in
    Printf.sprintf "[%s] %s (%s)" status_str agent.name elapsed_str
  ) agents

let split_tasks (tasks : Types.task list) =
  let active =
    List.filter (fun task ->
      match task.Types.task_status with
      | Types.InProgress _ | Types.Claimed _ -> true
      | Types.Todo | Types.Done _ | Types.Cancelled _ -> false
    ) tasks
  in
  let pending = List.filter (fun task -> task.Types.task_status = Types.Todo) tasks in
  (active, pending)

let task_lines (tasks : Types.task list) =
  let (active, pending) = split_tasks tasks in
  let content =
    (List.map (fun (task : Types.task) ->
      let assignee =
        match task.task_status with
        | Types.InProgress { assignee; _ } -> assignee
        | Types.Claimed { assignee; _ } -> assignee
        | Types.Todo | Types.Done _ | Types.Cancelled _ -> "?"
      in
      Printf.sprintf "[P%d] %s (@%s)" task.priority task.title assignee
    ) active)
    @ (List.filteri (fun idx _ -> idx < max_pending_tasks) pending
       |> List.map (fun (task : Types.task) ->
              Printf.sprintf "[P%d] %s (pending)" task.priority task.title))
  in
  let pending_more = List.length pending - max_pending_tasks in
  if pending_more > 0 then
    content @ [Printf.sprintf "   ... +%d more pending" pending_more]
  else
    content

let message_lines (messages : Types.message list) =
  List.map (fun (message : Types.message) ->
    Printf.sprintf "%s: %s" message.from_agent (truncate_message message.content)
  ) messages

let add_group label lines empty_msg =
  if lines = [] then
    [Printf.sprintf "%s: %s" label empty_msg]
  else
    (label ^ ":") :: List.map (fun line -> "  " ^ line) lines

let parse_worktrees (json : Yojson.Safe.t) : (string * string) list =
  let module U = Yojson.Safe.Util in
  match json |> U.member "worktrees" with
  | `List items ->
      List.filter_map (fun item ->
        try
          let worktree = item |> U.member "worktree" |> U.to_string in
          let branch = item |> U.member "branch" |> U.to_string in
          if String.length branch > 0 && not (String.equal branch "HEAD") then
            Some (branch, worktree)
          else None
        with
        | Yojson.Safe.Util.Type_error _ -> None
        | _ -> None
      ) items
  | `Null -> []
  | _ -> []

let worktrees_section (config : Room_utils.config) : section =
  let json = Room.worktree_list config in
  let worktrees = parse_worktrees json in
  let content = List.map (fun (branch, path) ->
    Printf.sprintf "%s -> %s" branch (truncate_path path)
  ) worktrees in
  { title = "Worktrees"; content; empty_msg = "(no worktrees)" }

let rec count_lock_files path =
  try
    if Sys.file_exists path then
      if Sys.is_directory path then
        let entries = Sys.readdir path |> Array.to_list in
        List.fold_left (fun acc name ->
          let full = Filename.concat path name in
          if Sys.is_directory full then
            acc + count_lock_files full
          else if Filename.check_suffix name ".flock" then
            acc
          else
            acc + 1
        ) 0 entries
      else
        0
    else
      0
  with Sys_error _ -> 0

let count_locks_for_dir (config : Room_utils.config) locks_dir =
  match config.backend with
  | Room_utils.FileSystem _ -> count_lock_files locks_dir
  | Room_utils.Memory _ | Room_utils.PostgresNative _ ->
      (match Room_utils.key_of_path config locks_dir with
       | Some key_prefix ->
           (match Room_utils.backend_list_keys config ~prefix:(key_prefix ^ ":") with
            | Ok keys -> List.length keys
            | Error _ -> 0)
       | None -> 0)

let count_locks_for_room (config : Room_utils.config) room_id =
  let locks_dir = Filename.concat (Room.room_path config room_id) "locks" in
  count_locks_for_dir config locks_dir

let tempo_section (config : Room_utils.config) : section =
  let state = Tempo.get_tempo config in
  let content = [Tempo.format_state state] in
  { title = "Tempo"; content; empty_msg = "" }

let dedupe_keep_order strings =
  let seen = Hashtbl.create 16 in
  List.filter (fun value ->
    if Hashtbl.mem seen value then false
    else (
      Hashtbl.add seen value ();
      true
    )
  ) strings

let ordered_room_ids (config : Room_utils.config) =
  let open Yojson.Safe.Util in
  let current_room = Room.current_room_id config in
  let result = Room.rooms_list config in
  let listed =
    match result |> member "rooms" with
    | `List rooms ->
        List.filter_map (fun room ->
          match room |> member "id" with
          | `String id when String.trim id <> "" -> Some id
          | _ -> None
        ) rooms
    | _ -> []
  in
  let room_ids =
    dedupe_keep_order (current_room :: "default" :: listed)
  in
  let others = List.filter (fun room_id -> not (String.equal room_id current_room)) room_ids in
  (current_room, current_room :: List.sort String.compare others)

let room_snapshot (config : Room_utils.config) ~current_room room_id =
  {
    room_id;
    is_current = String.equal room_id current_room;
    agents = Room.get_agents_raw_in_room config room_id;
    tasks = Room.get_tasks_raw_in_room config room_id;
    messages = Room.get_messages_raw_in_room config ~room_id ~since_seq:0 ~limit:max_recent_messages;
    locks = count_locks_for_room config room_id;
  }

let swarm_json (config : Room_utils.config) =
  if Room.is_initialized config then Swarm_status.build_json config
  else Swarm_status.empty_json

let swarm_lane_summaries now json =
  let open Yojson.Safe.Util in
  match json |> member "lanes" with
  | `List lanes ->
      lanes
      |> List.filter_map (fun lane ->
             match lane with
             | `Assoc _ ->
                 let label =
                   lane |> member "label" |> to_string_option
                   |> Option.value ~default:"Unknown lane"
                 in
                 let present = lane |> member "present" |> to_bool_option |> Option.value ~default:false in
                 let phase =
                   lane |> member "phase" |> to_string_option
                   |> Option.value ~default:"forming"
                 in
                 let motion_state =
                   lane |> member "motion_state" |> to_string_option
                   |> Option.value ~default:"waiting"
                 in
                 let current_step =
                   lane |> member "current_step" |> to_string_option
                   |> Option.value ~default:"Observe lane"
                 in
                 let age =
                   match lane |> member "last_movement_at" |> to_string_option with
                   | Some timestamp -> format_elapsed now timestamp "n/a"
                   | None -> "n/a"
                 in
                 let hard_flags =
                   match lane |> member "hard_flags" with
                   | `List flags ->
                       flags
                       |> List.filter_map (fun flag ->
                              flag |> member "code" |> to_string_option)
                   | _ -> []
                 in
                 Some { label; present; phase; motion_state; age; current_step; hard_flags }
             | _ -> None)
      |> List.filter (fun lane -> lane.present)
  | _ -> []

let swarm_section now (config : Room_utils.config) : section =
  let open Yojson.Safe.Util in
  let json = swarm_json config in
  let overview = json |> member "overview" in
  let active_lanes = overview |> member "active_lanes" |> to_int_option |> Option.value ~default:0 in
  let moving_lanes = overview |> member "moving_lanes" |> to_int_option |> Option.value ~default:0 in
  let stalled_lanes = overview |> member "stalled_lanes" |> to_int_option |> Option.value ~default:0 in
  let projected_lanes = overview |> member "projected_lanes" |> to_int_option |> Option.value ~default:0 in
  let last_movement =
    match overview |> member "last_movement_at" |> to_string_option with
    | Some timestamp -> format_elapsed now timestamp "n/a"
    | None -> "n/a"
  in
  let next_action = json |> member "recommended_next_action" in
  let next_label =
    next_action |> member "label" |> to_string_option
    |> Option.value ~default:"Observe operator state"
  in
  let next_tool =
    next_action |> member "tool" |> to_string_option
    |> Option.value ~default:"masc_operator_snapshot"
  in
  let gap_items =
    match json |> member "gaps" |> member "items" with
    | `List items ->
        items
        |> List.filter_map (fun item ->
               let code = item |> member "code" |> to_string_option in
               let count = item |> member "count" |> to_int_option |> Option.value ~default:0 in
               Option.map (fun code -> Printf.sprintf "%s (%d)" code count) code)
    | _ -> []
  in
  let lane_lines =
    swarm_lane_summaries now json
    |> List.map (fun lane ->
           let flags =
             match lane.hard_flags with
             | [] -> "none"
             | flags -> String.concat ", " flags
           in
           Printf.sprintf "%s: %s / %s / %s | step=%s | flags=%s"
             lane.label lane.phase lane.motion_state lane.age lane.current_step flags)
  in
  let content =
    [
      Printf.sprintf "Overview: %d active | %d moving | %d stalled | %d projected | last movement %s"
        active_lanes moving_lanes stalled_lanes projected_lanes last_movement;
      Printf.sprintf "Next Action: %s (%s)" next_label next_tool;
    ]
    @ (if gap_items = [] then [ "Hard Flags: none" ]
       else [ "Hard Flags: " ^ String.concat ", " gap_items ])
    @ add_group "Lanes" lane_lines "(no active lanes)"
  in
  { title = "Swarm"; content; empty_msg = "(no swarm activity)" }

let room_overview_section (snapshots : room_snapshot list) : section =
  let content =
    List.map (fun snapshot ->
      let (active, pending) = split_tasks snapshot.tasks in
      Printf.sprintf "%s%s: %d agents | %d active | %d pending | %d locks"
        snapshot.room_id
        (if snapshot.is_current then " (current)" else "")
        (List.length snapshot.agents)
        (List.length active)
        (List.length pending)
        snapshot.locks
    ) snapshots
  in
  { title = "Rooms"; content; empty_msg = "(no rooms)" }

let room_section now (snapshot : room_snapshot) : section =
  let (active, pending) = split_tasks snapshot.tasks in
  let content =
    [Printf.sprintf "Summary: %d agents | %d active | %d pending | %d locks"
       (List.length snapshot.agents)
       (List.length active)
       (List.length pending)
       snapshot.locks]
    @ add_group "Agents" (agent_lines now snapshot.agents) "(no agents)"
    @ add_group "Tasks" (task_lines snapshot.tasks) "(no tasks)"
    @ add_group "Recent Messages" (message_lines snapshot.messages) "(no messages)"
  in
  {
    title =
      if snapshot.is_current then
        Printf.sprintf "Room: %s (current)" snapshot.room_id
      else
        Printf.sprintf "Room: %s" snapshot.room_id;
    content;
    empty_msg = "";
  }

let agents_section now (agents : Types.agent list) : section =
  let content = agent_lines now agents in
  { title = "Agents"; content; empty_msg = "(no agents)" }

let tasks_section (tasks : Types.task list) : section =
  let content = task_lines tasks in
  { title = "Tasks"; content; empty_msg = "(no tasks)" }

let messages_section (messages : Types.message list) : section =
  let content = message_lines messages in
  { title = "Recent Messages"; content; empty_msg = "(no messages)" }

let locks_section locks : section =
  let content = [Printf.sprintf "%d" locks] in
  { title = "Locks"; content; empty_msg = "0" }

let count_locks (config : Room_utils.config) : int =
  count_locks_for_room config (Room.current_room_id config)

(* Agent workflow summaries: recent activity per active agent *)
let agent_workflow_section now (_config : Room_utils.config) (agents : Types.agent list) : section =
  let content =
    agents
    |> List.filter (fun (a : Types.agent) ->
           match a.status with Types.Active | Types.Busy -> true | _ -> false)
    |> List.map (fun (agent : Types.agent) ->
           let status_icon =
             match agent.status with
             | Types.Active -> "[active]"
             | Types.Busy -> "[busy]"
             | _ -> "[idle]"
           in
           let task_info =
             match agent.current_task with
             | Some t -> Printf.sprintf " task=%s" (truncate_message t)
             | None -> ""
           in
           let elapsed = format_elapsed now agent.last_seen agent.last_seen in
           Printf.sprintf "%s %s %s%s" agent.name status_icon elapsed task_info)
  in
  { title = "Agent Workflows"; content; empty_msg = "(no active agents)" }

let generate ?(scope = All) (config : Room_utils.config) : string =
  let now = Time_compat.now () in
  let timestamp =
    let tm = Unix.localtime now in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let (current_room, room_ids) = ordered_room_ids config in
  let snapshots = List.map (room_snapshot config ~current_room) room_ids in
  let header =
    Printf.sprintf
      "========================================\n   MASC Dashboard   %s\n   Scope: %s | Current Room: %s | Rooms: %d\n========================================"
      timestamp
      (match scope with All -> "all" | Current -> "current")
      current_room
      (List.length room_ids)
  in
  let sections =
    match scope with
    | All ->
        let all_agents = List.concat_map (fun s -> s.agents) snapshots in
        [
          room_overview_section snapshots;
          agent_workflow_section now config all_agents;
          swarm_section now config;
          tempo_section config;
          worktrees_section config;
        ]
        @ List.map (room_section now) snapshots
    | Current ->
        let snapshot = room_snapshot config ~current_room current_room in
        [
          agents_section now snapshot.agents;
          agent_workflow_section now config snapshot.agents;
          tasks_section snapshot.tasks;
          messages_section snapshot.messages;
          locks_section snapshot.locks;
          swarm_section now config;
          tempo_section config;
          worktrees_section config;
        ]
  in
  let section_strs = List.map format_section sections in
  String.concat "\n\n" ([header] @ section_strs @ ["\nRefresh: watch -n 1 masc dashboard"])

let generate_compact ?(scope = All) (config : Room_utils.config) : string =
  let tempo = Tempo.get_tempo config in
  let (current_room, room_ids) = ordered_room_ids config in
  let now = Time_compat.now () in
  let snapshots =
    match scope with
    | All -> List.map (room_snapshot config ~current_room) room_ids
    | Current -> [room_snapshot config ~current_room current_room]
  in
  let (agents_count, active_count, pending_count, locks_count) =
    List.fold_left (fun (agents_acc, active_acc, pending_acc, locks_acc) snapshot ->
      let (active, pending) = split_tasks snapshot.tasks in
      ( agents_acc + List.length snapshot.agents,
        active_acc + List.length active,
        pending_acc + List.length pending,
        locks_acc + snapshot.locks )
    ) (0, 0, 0, 0) snapshots
  in
  let swarm = swarm_json config in
  let open Yojson.Safe.Util in
  let overview = swarm |> member "overview" in
  let moving_lanes = overview |> member "moving_lanes" |> to_int_option |> Option.value ~default:0 in
  let stalled_lanes = overview |> member "stalled_lanes" |> to_int_option |> Option.value ~default:0 in
  let projected_lanes = overview |> member "projected_lanes" |> to_int_option |> Option.value ~default:0 in
  let last_movement =
    match overview |> member "last_movement_at" |> to_string_option with
    | Some timestamp -> format_elapsed now timestamp "n/a"
    | None -> "n/a"
  in
  let next_action =
    swarm |> member "recommended_next_action" |> member "label" |> to_string_option
    |> Option.value ~default:"Observe operator state"
  in
  Printf.sprintf
    "Scope: %s | Rooms: %d | Current: %s | Agents: %d | Tasks: %d active, %d pending | Locks: %d | Swarm: %d moving, %d stalled, %d projected, last %s | Next: %s | Tempo: %.0fs"
    (match scope with All -> "all" | Current -> "current")
    (List.length snapshots)
    current_room
    agents_count
    active_count
    pending_count
    locks_count
    moving_lanes
    stalled_lanes
    projected_lanes
    last_movement
    next_action
    tempo.Tempo.current_interval_s
