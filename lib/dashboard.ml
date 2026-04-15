(** MASC Dashboard - Operator-First Status Visualization

    Usage:
    - MCP: masc_dashboard
    - CLI: masc dashboard | watch -n 1 masc dashboard

    Information hierarchy (operator questions drive section order):
    1. ATTENTION REQUIRED — what needs my action right now?
    2. AGENTS — who is working, stuck, or idle?
    3. TOP TASKS — what are the important tasks?
    4. SWARM HEALTH — is the system healthy?
    5. RECENT ACTIVITY — what just happened?
    6. Footer — tempo, locks, worktrees (one line)
*)

(* ===== Runtime-tunable parameters =====
   Values come from Runtime_params via Governance_registry. Call these
   as thunks to pick up governance overrides without restart. *)

(** Maximum path length before truncation. *)
let max_path_length () = Runtime_params.get Governance_registry.dashboard_max_path_length

(** Maximum message content length before truncation. *)
let max_message_length () = Runtime_params.get Governance_registry.dashboard_max_message_length

(** Maximum pending tasks to show. *)
let max_pending_tasks () = Runtime_params.get Governance_registry.dashboard_max_pending_tasks

(** Maximum recent messages to show. *)
let max_recent_messages () = Runtime_params.get Governance_registry.dashboard_max_recent_messages

(** Minimum section border length. *)
let min_border_length () = Runtime_params.get Governance_registry.dashboard_min_border_length

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

(** Re-export shared types from Dashboard_labels to avoid breaking existing callers *)
type room_snapshot = Dashboard_labels.room_snapshot = {
  room_id: string;
  is_current: bool;
  agents: Types.agent list;
  tasks: Types.task list;
  messages: Types.message list;
  locks: int;
}

type swarm_lane_summary = Dashboard_labels.swarm_lane_summary = {
  label: string;
  present: bool;
  phase: Swarm_status_types.lane_phase;
  motion_state: Swarm_status_types.lane_motion;
  age: string;
  current_step: string;
  hard_flags: Swarm_status_types.flag_code list;
}

(** Format a section *)
let format_section (s : section) : string =
  let header = Printf.sprintf "== %s ==" s.title in
  let border_len = max (min_border_length ()) (String.length header + 4) in
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

(** Delegate to Dashboard_labels (canonical implementation) *)
let parse_iso_timestamp = Dashboard_labels.parse_iso_timestamp
let format_elapsed = Dashboard_labels.format_elapsed

let truncate_path (path : string) : string =
  let limit = max_path_length () in
  if String.length path > limit then
    let suffix_len = limit - 3 in
    "..." ^ String.sub path (String.length path - suffix_len) suffix_len
  else path

let truncate_message (msg : string) : string =
  let limit = max_message_length () in
  if String.length msg > limit then
    let prefix_len = limit - 3 in
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
  let pending_limit = max_pending_tasks () in
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
    @ (List.filteri (fun idx _ -> idx < pending_limit) pending
       |> List.map (fun (task : Types.task) ->
              Printf.sprintf "[P%d] %s (pending)" task.priority task.title))
  in
  let pending_more = List.length pending - pending_limit in
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

let normalize_worktree_branch branch =
  let branch = String.trim branch in
  let prefix = "refs/heads/" in
  if String.length branch >= String.length prefix
     && String.sub branch 0 (String.length prefix) = prefix then
    String.sub branch (String.length prefix)
      (String.length branch - String.length prefix)
  else
    branch

let worktree_path_of_json item =
  let module U = Yojson.Safe.Util in
  match item |> U.member "path" with
  | `String path when String.trim path <> "" -> Some path
  | _ ->
      (match item |> U.member "worktree" with
       | `String path when String.trim path <> "" -> Some path
       | _ -> None)

let parse_worktrees (json : Yojson.Safe.t) : (string * string) list =
  let module U = Yojson.Safe.Util in
  match json |> U.member "worktrees" with
  | `List items ->
      List.filter_map
        (fun item ->
          match item with
          | `Assoc _ ->
              let branch =
                match item |> U.member "branch" with
                | `String raw_branch -> Some (normalize_worktree_branch raw_branch)
                | _ -> None
              in
              (match worktree_path_of_json item, branch with
               | Some worktree, Some branch
                 when String.length branch > 0 && not (String.equal branch "HEAD") ->
                   Some (branch, worktree)
               | _ -> None)
          | _ -> None)
        items
  | `Null -> []
  | _ -> []

let worktrees_section (config : Coord_utils.config) : section =
  let json = Coord.worktree_list config in
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

let count_locks_for_dir (config : Coord_utils.config) locks_dir =
  match config.backend with
  | Coord_utils.FileSystem _ -> count_lock_files locks_dir
  | Coord_utils.Memory _ ->
      (match Coord_utils.key_of_path config locks_dir with
       | Some key_prefix ->
           (match Coord_utils.backend_list_keys config ~prefix:(key_prefix ^ ":") with
            | Ok keys -> List.length keys
            | Error _ -> 0)
       | None -> 0)

let count_locks_for_room (config : Coord_utils.config) room_id =
  let locks_dir = Filename.concat (Coord.room_dir_for config room_id) "locks" in
  count_locks_for_dir config locks_dir

let tempo_section (config : Coord_utils.config) : section =
  let state = Tempo.get_tempo config in
  let content = [Tempo.format_state state] in
  { title = "Tempo"; content; empty_msg = "" }

let ordered_room_ids (_config : Coord_utils.config) =
  let current_room = "default" in
  (current_room, [ current_room ])

let room_snapshot (config : Coord_utils.config) ~current_room room_id =
  {
    room_id;
    is_current = String.equal room_id current_room;
    agents = Coord.get_active_agents config;
    tasks = Coord.get_tasks_safe config;
    messages = Coord.get_messages_raw config ~since_seq:0 ~limit:(max_recent_messages ());
    locks = count_locks_for_room config room_id;
  }

let swarm_json (config : Coord_utils.config) =
  if Coord.is_initialized config then Swarm_status.build_json config
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
                   |> Swarm_status_json.lane_phase_of_string
                 in
                 let motion_state =
                   lane |> member "motion_state" |> to_string_option
                   |> Option.value ~default:"waiting"
                   |> Swarm_status_json.lane_motion_of_string
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
                              flag |> member "code" |> to_string_option
                              |> (fun opt -> Option.bind opt Swarm_status_json.flag_code_of_string))
                   | _ -> []
                 in
                 Some { label; present; phase; motion_state; age; current_step; hard_flags }
             | _ -> None)
      |> List.filter (fun lane -> lane.present)
  | _ -> []

(** Operator-friendly swarm health section with translated labels *)
let swarm_health_section now (_config : Coord_utils.config) (json : Yojson.Safe.t) : section =
  let open Yojson.Safe.Util in
  let lanes = swarm_lane_summaries now json in
  let next_action = json |> member "recommended_next_action" in
  let next_label =
    next_action |> member "label" |> to_string_option
    |> Option.value ~default:"Observe operator state"
  in
  let next_tool =
    next_action |> member "tool" |> to_string_option
    |> Option.value ~default:"masc_operator_snapshot"
  in
  let verdict = Dashboard_labels.health_verdict lanes in
  let lane_lines =
    lanes
    |> List.map (fun (lane : swarm_lane_summary) ->
           let status =
             Dashboard_labels.translate_lane_status ~phase:lane.phase
               ~motion_state:lane.motion_state ~age:lane.age
           in
           let extras =
             match lane.hard_flags with
             | [] -> ""
             | flags ->
                 " | "
                 ^ String.concat ", "
                     (List.map Dashboard_labels.translate_flag_code flags)
           in
           Printf.sprintf "%s: %s%s" lane.label status extras)
  in
  let content =
    [ verdict ]
    @ (if lane_lines = [] then [ "(no active lanes)" ]
       else [ "" ] @ lane_lines)
    @ [ ""; Printf.sprintf "Next: %s (%s)" next_label next_tool ]
  in
  { title = "Swarm Health"; content; empty_msg = "(no swarm activity)" }

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
  { title = "Namespaces"; content; empty_msg = "(no namespaces)" }

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
        Printf.sprintf "Namespace: %s (flattened current)" snapshot.room_id
      else
        Printf.sprintf "Namespace: %s" snapshot.room_id;
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

let count_locks (config : Coord_utils.config) : int =
  count_locks_for_room config "default"

(* Agent workflow summaries: recent activity per active agent *)
let agent_workflow_section now (_config : Coord_utils.config) (agents : Types.agent list) : section =
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

(** Operator-friendly agents section grouped by Working / Stuck / Idle *)
let agents_grouped_section now (agents : Types.agent list) : section =
  let format_agent (agent : Types.agent) =
    let status_label =
      Dashboard_labels.translate_agent_status ~now agent.status agent.last_seen
    in
    let elapsed = format_elapsed now agent.last_seen "" in
    let task_info =
      match agent.current_task with
      | Some t -> truncate_message t
      | None -> "(unassigned)"
    in
    Printf.sprintf "%-20s %-10s %s" agent.name elapsed task_info
    ^ (if String.length status_label > 0 then "" else "")
    (* status is reflected in the group header *)
  in
  let working =
    List.filter
      (fun a ->
        Dashboard_labels.classify_agent ~now a = Dashboard_labels.Working)
      agents
  in
  let stuck =
    List.filter
      (fun a ->
        Dashboard_labels.classify_agent ~now a = Dashboard_labels.Stuck)
      agents
  in
  let idle =
    List.filter
      (fun a ->
        Dashboard_labels.classify_agent ~now a = Dashboard_labels.Idle)
      agents
  in
  let offline =
    List.filter
      (fun a ->
        Dashboard_labels.classify_agent ~now a = Dashboard_labels.Offline)
      agents
  in
  let content =
    (if working <> [] then
       add_group "Working" (List.map format_agent working) ""
     else [])
    @ (if stuck <> [] then
         add_group "Stuck" (List.map format_agent stuck) ""
       else [])
    @ (if idle <> [] then
         add_group "Idle" (List.map format_agent idle) ""
       else [])
    @ (if offline <> [] then
         add_group "Offline" (List.map format_agent offline) ""
       else [])
  in
  { title = "Agents"; content; empty_msg = "(no agents)" }

(** Format elapsed seconds from a Unix timestamp to now. *)
let format_elapsed_float now ts =
  let elapsed = now -. ts in
  if elapsed < 0.0 then "0s"
  else if elapsed < 60.0 then Printf.sprintf "%.0fs" elapsed
  else if elapsed < 3600.0 then Printf.sprintf "%.0fm" (elapsed /. 60.0)
  else Printf.sprintf "%.1fh" (elapsed /. 3600.0)

(** Keepers section: real-time FSM phase from Keeper_registry.
    Reads registry snapshot each render — no dashboard-side cache. *)
let keepers_section now : section =
  let entries = Keeper_registry.all () in
  let sorted =
    List.sort (fun (a : Keeper_registry.registry_entry) b ->
      String.compare a.name b.name) entries
  in
  let format_entry (e : Keeper_registry.registry_entry) =
    let phase_str = Keeper_state_machine.phase_to_string e.phase in
    let since =
      match e.phase with
      | Dead ->
        (match e.dead_since_ts with
         | Some ts -> format_elapsed_float now ts
         | None -> "?")
      | _ -> format_elapsed_float now e.started_at
    in
    let last_info =
      match e.last_error with
      | Some err ->
        Printf.sprintf " | err=%s" (truncate_message err)
      | None -> ""
    in
    Printf.sprintf "%s: %s | seq=%d | since=%s%s"
      e.name phase_str e.transition_seq since last_info
  in
  let content = List.map format_entry sorted in
  { title = "Keepers"; content; empty_msg = "(no keepers registered)" }

(** Attention section: items requiring operator action *)
let attention_section now (snapshots : room_snapshot list)
    (swarm_json_data : Yojson.Safe.t) : section =
  let items = Dashboard_attention.collect ~now snapshots swarm_json_data in
  let content = Dashboard_attention.format_items items in
  { title = "Attention Required"; content; empty_msg = "No action needed" }

let generate ?(scope = All) (config : Coord_utils.config) : string =
  let now = Time_compat.now () in
  let timestamp =
    let tm = Unix.localtime now in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let (current_room, room_ids) = ordered_room_ids config in
  let snapshots =
    match scope with
    | All -> List.map (room_snapshot config ~current_room) room_ids
    | Current -> [room_snapshot config ~current_room current_room]
  in
  let all_agents = List.concat_map (fun s -> s.agents) snapshots in
  let all_tasks = List.concat_map (fun s -> s.tasks) snapshots in
  let swarm = swarm_json config in
  let header =
    Printf.sprintf
      "========================================\n   MASC Dashboard   %s\n   Namespace: %s (flattened) | %d namespace%s | %d agents\n========================================"
      timestamp
      current_room
      (List.length room_ids)
      (if List.length room_ids > 1 then "s" else "")
      (List.length all_agents)
  in
  (* Operator-first section order *)
  let sections =
    [
      attention_section now snapshots swarm;
      agents_grouped_section now all_agents;
      keepers_section now;
      tasks_section all_tasks;
      swarm_health_section now config swarm;
      messages_section
        (List.concat_map (fun s -> s.messages) snapshots);
    ]
  in
  let tempo = Tempo.get_tempo config in
  let worktrees = parse_worktrees (Coord.worktree_list config) in
  let total_locks =
    List.fold_left (fun acc s -> acc + s.locks) 0 snapshots
  in
  let footer =
    Printf.sprintf "-- Tempo: %.0fs | Locks: %d | Worktrees: %d"
      tempo.Tempo.current_interval_s total_locks (List.length worktrees)
  in
  let section_strs = List.map format_section sections in
  String.concat "\n\n" ([header] @ section_strs @ [footer])

let generate_compact ?(scope = All) (config : Coord_utils.config) : string =
  let (current_room, room_ids) = ordered_room_ids config in
  let now = Time_compat.now () in
  let snapshots =
    match scope with
    | All -> List.map (room_snapshot config ~current_room) room_ids
    | Current -> [room_snapshot config ~current_room current_room]
  in
  let all_agents = List.concat_map (fun s -> s.agents) snapshots in
  let all_tasks = List.concat_map (fun s -> s.tasks) snapshots in
  let (active_tasks, pending_tasks) = split_tasks all_tasks in
  let blocked_tasks =
    List.filter (fun (t : Types.task) ->
      match t.task_status with
      | Types.Claimed _ -> true (* claimed but not in-progress = potentially blocked *)
      | _ -> false
    ) all_tasks
  in
  (* Agent counts by group *)
  let working_count =
    List.length
      (List.filter
         (fun a -> Dashboard_labels.classify_agent ~now a = Dashboard_labels.Working)
         all_agents)
  in
  let stuck_count =
    List.length
      (List.filter
         (fun a -> Dashboard_labels.classify_agent ~now a = Dashboard_labels.Stuck)
         all_agents)
  in
  let idle_count =
    List.length
      (List.filter
         (fun a -> Dashboard_labels.classify_agent ~now a = Dashboard_labels.Idle)
         all_agents)
  in
  let offline_count =
    List.length all_agents - working_count - stuck_count - idle_count
  in
  (* Keeper phase summary *)
  let keeper_entries = Keeper_registry.all () in
  let keeper_by_phase phase =
    List.length (List.filter
      (fun (e : Keeper_registry.registry_entry) -> e.phase = phase)
      keeper_entries)
  in
  let k_running = keeper_by_phase Running in
  let k_dead = keeper_by_phase Dead in
  let k_other = List.length keeper_entries - k_running - k_dead in
  (* Swarm health *)
  let swarm = swarm_json config in
  let lanes = swarm_lane_summaries now swarm in
  let health = Dashboard_labels.health_verdict lanes in
  (* Attention *)
  let attention_items = Dashboard_attention.collect ~now snapshots swarm in
  let attention_line = Dashboard_attention.compact_summary attention_items in
  (* Next action *)
  let open Yojson.Safe.Util in
  let next_tool =
    swarm |> member "recommended_next_action" |> member "tool"
    |> to_string_option |> Option.value ~default:"masc_observe_swarm"
  in
  String.concat "\n"
    [
      Printf.sprintf "MASC [%s namespace] %d agents / %d tasks"
        current_room (List.length all_agents)
        (List.length all_tasks);
      Printf.sprintf "ATTENTION: %s" attention_line;
      Printf.sprintf "AGENTS: %d working / %d idle / %d stuck / %d offline | TASKS: %d active / %d pending / %d blocked"
        working_count idle_count stuck_count offline_count
        (List.length active_tasks) (List.length pending_tasks)
        (List.length blocked_tasks);
      Printf.sprintf "KEEPERS: %d running / %d dead / %d other"
        k_running k_dead k_other;
      Printf.sprintf "HEALTH: %s | Next: %s" health next_tool;
    ]
