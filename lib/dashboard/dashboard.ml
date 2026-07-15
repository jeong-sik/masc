module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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
    6. Footer — tempo and locks (one line)
*)

(* ===== Runtime-tunable parameters =====
   Values come from Runtime_params via Runtime_settings. Call these
   as thunks to pick up runtime updates without restart. *)

(** Maximum path length before truncation. *)
let max_path_length () = Runtime_params.get Runtime_settings.dashboard_max_path_length

(** Maximum message content length before truncation. *)
let max_message_length () = Runtime_params.get Runtime_settings.dashboard_max_message_length

(** Maximum pending tasks to show. *)
let max_pending_tasks () = Runtime_params.get Runtime_settings.dashboard_max_pending_tasks

(** Maximum recent messages to show. *)
let max_recent_messages () = Runtime_params.get Runtime_settings.dashboard_max_recent_messages

(** Minimum section border length. *)
let min_border_length () = Runtime_params.get Runtime_settings.dashboard_min_border_length

(* ===== Masc_domain ===== *)

(** Dashboard section *)
type section = {
  title: string;
  content: string list;
  empty_msg: string;
}

type scope =
  | All
  | Current

(** Issue #8592: SSOT helpers for [scope]. The witness function and
    canonical string list are mirrored in the JSON Schema layer
    ([Tool_schemas_misc.dashboard_scope_enum_strings]) — direct
    dependency would cycle. The test [test_types.ml ::
    dashboard_scope_ssot] asserts the mirror stays in sync. Adding a
    new constructor here forces a compile error in [scope_to_string]
    and fails the schema mirror test instead of silently dropping
    from the enum. *)
let scope_to_string = function
  | All -> "all"
  | Current -> "current"

let all_scopes = [ All; Current ]

let valid_scope_strings = List.map scope_to_string all_scopes

let scope_of_string_opt = function
  | "all" -> Some All
  | "current" -> Some Current
  | _ -> None

(** Re-export shared types from Dashboard_labels to avoid breaking existing callers *)
type workspace_snapshot = Dashboard_labels.workspace_snapshot = {
  workspace_id: string;
  agents: Masc_domain.agent list;
  tasks: Masc_domain.task list;
  messages: Masc_domain.message list;
  locks: int;
}

(** Format a section *)
let format_section (s : section) : string =
  let header = Printf.sprintf "== %s ==" s.title in
  let border_len = max (min_border_length ()) (String.length header + 4) in
  let top_border = header ^ String.make (border_len - String.length header) '=' in
  let bottom_border = String.make border_len '-' in
  let content =
    if Stdlib.List.length s.content = 0 then
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
  String_util.utf8_safe ~max_bytes:limit ~suffix:"..." msg
  |> String_util.to_string

let agent_lines now (agents : Masc_domain.agent list) =
  List.map (fun (agent : Masc_domain.agent) ->
    let status_str = Masc_domain.agent_status_to_string agent.status in
    let elapsed_str = format_elapsed now agent.last_seen agent.last_seen in
    Printf.sprintf "[%s] %s (%s)" status_str agent.name elapsed_str
  ) agents

let split_tasks (tasks : Masc_domain.task list) =
  let active =
    List.filter (fun task ->
      match task.Masc_domain.task_status with
      | Masc_domain.InProgress _ | Masc_domain.Claimed _ | Masc_domain.AwaitingVerification _ -> true
      | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false
    ) tasks
  in
  let pending = List.filter (fun task -> (=) task.Masc_domain.task_status Masc_domain.Todo) tasks in
  (active, pending)

let task_lines (tasks : Masc_domain.task list) =
  let (active, pending) = split_tasks tasks in
  let pending_limit = max_pending_tasks () in
  let content =
    (List.map (fun (task : Masc_domain.task) ->
      let assignee =
        match task.task_status with
        | Masc_domain.InProgress { assignee; _ } -> assignee
        | Masc_domain.Claimed { assignee; _ } -> assignee
        | Masc_domain.AwaitingVerification { assignee; _ } -> assignee
        | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> "?"
      in
      Printf.sprintf "[P%d] %s (@%s)" task.priority task.title assignee
    ) active)
    @ (List.filteri (fun idx _ -> idx < pending_limit) pending
       |> List.map (fun (task : Masc_domain.task) ->
              Printf.sprintf "[P%d] %s (pending)" task.priority task.title))
  in
  let pending_more = List.length pending - pending_limit in
  if pending_more > 0 then
    content @ [Printf.sprintf "   ... +%d more pending" pending_more]
  else
    content

let message_lines (messages : Masc_domain.message list) =
  List.map (fun (message : Masc_domain.message) ->
    Printf.sprintf "%s: %s" message.from_agent (truncate_message message.content)
  ) messages

let add_group label lines empty_msg =
  if Stdlib.List.length lines = 0 then
    [Printf.sprintf "%s: %s" label empty_msg]
  else
    (label ^ ":") :: List.map (fun line -> "  " ^ line) lines

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

let count_locks_for_dir (config : Workspace_utils.config) locks_dir =
  match config.backend with
  | Workspace_utils.FileSystem _ -> count_lock_files locks_dir
  | Workspace_utils.Memory _ ->
      (match Workspace_utils.key_of_path config locks_dir with
       | Some key_prefix ->
           (match Workspace_utils.backend_list_keys config ~prefix:(key_prefix ^ ":") with
            | Ok keys -> List.length keys
            | Error _ -> 0)
       | None -> 0)

let count_locks_for_workspace (config : Workspace_utils.config) =
  let locks_dir = Filename.concat (Workspace.masc_dir config) "locks" in
  count_locks_for_dir config locks_dir

let tempo_section (config : Workspace_utils.config) : section =
  let state = Tempo.get_tempo config in
  let content = [Tempo.format_state state] in
  { title = "Tempo"; content; empty_msg = "" }

let active_workspace_id = "workspace"

let workspace_snapshot (config : Workspace_utils.config) =
  {
    workspace_id = active_workspace_id;
    agents = Workspace.get_active_agents config;
    tasks = Workspace.get_tasks_safe config;
    messages = Workspace.get_messages_raw config ~since_seq:0 ~limit:(max_recent_messages ());
    locks = count_locks_for_workspace config;
  }

let workspace_overview_section (snapshots : workspace_snapshot list) : section =
  let content =
    List.map (fun snapshot ->
      let (active, pending) = split_tasks snapshot.tasks in
      Printf.sprintf "%s: %d agents | %d active | %d pending | %d locks"
        snapshot.workspace_id
        (List.length snapshot.agents)
        (List.length active)
        (List.length pending)
        snapshot.locks
    ) snapshots
  in
  { title = "Workspace"; content; empty_msg = "(no workspace data)" }

let workspace_section now (snapshot : workspace_snapshot) : section =
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
  { title = Printf.sprintf "Workspace: %s" snapshot.workspace_id; content; empty_msg = "" }

let agents_section now (agents : Masc_domain.agent list) : section =
  let content = agent_lines now agents in
  { title = "Agents"; content; empty_msg = "(no agents)" }

let tasks_section (tasks : Masc_domain.task list) : section =
  let content = task_lines tasks in
  { title = "Tasks"; content; empty_msg = "(no tasks)" }

let messages_section (messages : Masc_domain.message list) : section =
  let content = message_lines messages in
  { title = "Recent Messages"; content; empty_msg = "(no messages)" }

let locks_section locks : section =
  let content = [Printf.sprintf "%d" locks] in
  { title = "Locks"; content; empty_msg = "0" }

let count_locks (config : Workspace_utils.config) : int =
  count_locks_for_workspace config

(* Agent workflow summaries: recent activity per active agent *)
let agent_workflow_section now (_config : Workspace_utils.config) (agents : Masc_domain.agent list) : section =
  let content =
    agents
    |> List.filter (fun (a : Masc_domain.agent) ->
           match a.status with Masc_domain.Active | Masc_domain.Busy -> true | Masc_domain.Listening | Masc_domain.Inactive -> false)
    |> List.map (fun (agent : Masc_domain.agent) ->
           let status_icon =
             match agent.status with
             | Masc_domain.Active -> "[active]"
             | Masc_domain.Busy -> "[busy]"
             | Masc_domain.Listening | Masc_domain.Inactive -> "[idle]"
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
let agents_grouped_section now (agents : Masc_domain.agent list) : section =
  let format_agent (agent : Masc_domain.agent) =
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
        (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Working)
      agents
  in
  let stuck =
    List.filter
      (fun a ->
        (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Stuck)
      agents
  in
  let idle =
    List.filter
      (fun a ->
        (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Idle)
      agents
  in
  let offline =
    List.filter
      (fun a ->
        (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Offline)
      agents
  in
  let content =
    (if Stdlib.List.length working > 0 then
       add_group "Working" (List.map format_agent working) ""
     else [])
    @ (if Stdlib.List.length stuck > 0 then
         add_group "Stuck" (List.map format_agent stuck) ""
       else [])
    @ (if Stdlib.List.length idle > 0 then
         add_group "Idle" (List.map format_agent idle) ""
       else [])
    @ (if Stdlib.List.length offline > 0 then
         add_group "Offline" (List.map format_agent offline) ""
       else [])
  in
  { title = "Agents"; content; empty_msg = "(no agents)" }

(** Format elapsed seconds from a Unix timestamp to now. *)
let format_elapsed_float now ts =
  let elapsed = now -. ts in
  if Stdlib.Float.compare elapsed 0.0 < 0 then "0s"
  else if Stdlib.Float.compare elapsed 60.0 < 0 then Printf.sprintf "%.0fs" elapsed
  else if Stdlib.Float.compare elapsed Masc_time_constants.hour < 0 then Printf.sprintf "%.0fm" (elapsed /. 60.0)
  else Printf.sprintf "%.1fh" (elapsed /. Masc_time_constants.hour)

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
  let guard_violations =
    Otel_metric_store.metric_total Otel_metric_store.metric_fsm_guard_violation |> int_of_float
  in
  let write_meta_failures =
    Otel_metric_store.metric_total Keeper_metrics.(to_string WriteMetaFailures) |> int_of_float
  in
  let tool_failures =
    (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolSelectionFailures) |> int_of_float)
    + (Otel_metric_store.metric_total Keeper_metrics.(to_string TaskLoadFailures) |> int_of_float)
  in
  let title =
    match guard_violations, write_meta_failures, tool_failures with
    | 0, 0, 0 -> "Keepers"
    | gv, 0, 0 -> Printf.sprintf "Keepers (guard violations: %d)" gv
    | 0, wm, 0 -> Printf.sprintf "Keepers (meta write errors: %d)" wm
    | 0, 0, tf -> Printf.sprintf "Keepers (tool errors: %d)" tf
    | gv, wm, 0 ->
        Printf.sprintf "Keepers (guard violations: %d, meta write errors: %d)" gv wm
    | gv, 0, tf ->
        Printf.sprintf "Keepers (guard violations: %d, tool errors: %d)" gv tf
    | 0, wm, tf ->
        Printf.sprintf "Keepers (meta write errors: %d, tool errors: %d)" wm tf
    | gv, wm, tf ->
        Printf.sprintf "Keepers (guard violations: %d, meta write errors: %d, tool errors: %d)" gv wm tf
  in
  { title; content; empty_msg = "(no keepers registered)" }

(** Attention section: items requiring operator action *)
let attention_section now (snapshots : workspace_snapshot list) : section =
  let items = Dashboard_attention.collect ~now snapshots in
  let content = Dashboard_attention.format_items items in
  { title = "Attention Required"; content; empty_msg = "No action needed" }

let generate ?(scope = All) (config : Workspace_utils.config) : string =
  let now = Time_compat.now () in
  let timestamp =
    let tm = Unix.localtime now in
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let _scope = scope in
  let snapshots = [ workspace_snapshot config ] in
  let workspace_id = active_workspace_id in
  let all_agents = List.concat_map (fun s -> s.agents) snapshots in
  let all_tasks = List.concat_map (fun s -> s.tasks) snapshots in
  let header =
    Printf.sprintf
      "========================================\n   MASC Dashboard   %s\n   Workspace: %s | %d agents\n========================================"
      timestamp
      workspace_id
      (List.length all_agents)
  in
  (* Operator-first section order *)
  let sections =
    [
      attention_section now snapshots;
      agents_grouped_section now all_agents;
      keepers_section now;
      tasks_section all_tasks;
      messages_section
        (List.concat_map (fun s -> s.messages) snapshots);
    ]
  in
  let tempo = Tempo.get_tempo config in
  let total_locks =
    List.fold_left (fun acc s -> acc + s.locks) 0 snapshots
  in
  let footer =
    Printf.sprintf "-- Tempo: %.0fs | Locks: %d"
      tempo.Tempo.current_interval_s total_locks
  in
  let section_strs = List.map format_section sections in
  String.concat "\n\n" ([header] @ section_strs @ [footer])

let generate_compact ?(scope = All) (config : Workspace_utils.config) : string =
  let _scope = scope in
  let now = Time_compat.now () in
  let snapshots = [ workspace_snapshot config ] in
  let workspace_id = active_workspace_id in
  let all_agents = List.concat_map (fun s -> s.agents) snapshots in
  let all_tasks = List.concat_map (fun s -> s.tasks) snapshots in
  let (active_tasks, pending_tasks) = split_tasks all_tasks in
  let blocked_tasks =
    List.filter (fun (t : Masc_domain.task) ->
      match t.task_status with
      | Masc_domain.Claimed _ -> true (* claimed but not in-progress = potentially blocked *)
      | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false
    ) all_tasks
  in
  (* Agent counts by group *)
  let working_count =
    List.length
      (List.filter
         (fun a -> (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Working)
         all_agents)
  in
  let stuck_count =
    List.length
      (List.filter
         (fun a -> (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Stuck)
         all_agents)
  in
  let idle_count =
    List.length
      (List.filter
         (fun a -> (=) (Dashboard_labels.classify_agent ~now a) Dashboard_labels.Idle)
         all_agents)
  in
  let offline_count =
    List.length all_agents - working_count - stuck_count - idle_count
  in
  (* Keeper phase summary *)
  let keeper_entries = Keeper_registry.all () in
  let keeper_by_phase phase =
    List_util.count_if
      (fun (e : Keeper_registry.registry_entry) -> (=) e.phase phase)
      keeper_entries
  in
  let k_running = keeper_by_phase Running in
  let k_dead = keeper_by_phase Dead in
  let k_other = List.length keeper_entries - k_running - k_dead in
  (* Attention *)
  let attention_items = Dashboard_attention.collect ~now snapshots in
  let attention_line = Dashboard_attention.compact_summary attention_items in
  String.concat "\n"
    [
      Printf.sprintf "MASC [%s workspace] %d agents / %d tasks"
        workspace_id (List.length all_agents)
        (List.length all_tasks);
      Printf.sprintf "ATTENTION: %s" attention_line;
      Printf.sprintf "AGENTS: %d working / %d idle / %d stuck / %d offline | TASKS: %d active / %d pending / %d blocked"
        working_count idle_count stuck_count offline_count
        (List.length active_tasks) (List.length pending_tasks)
        (List.length blocked_tasks);
      let guard_violations =
        Otel_metric_store.metric_total Otel_metric_store.metric_fsm_guard_violation |> int_of_float
      in
      let write_meta_failures =
        Otel_metric_store.metric_total Keeper_metrics.(to_string WriteMetaFailures) |> int_of_float
      in
      let tool_failures =
        (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolSelectionFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TaskLoadFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ReconcileFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string DecisionAuditFlushFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string PersonaDriftMissing) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string WorkspaceInitFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string PresenceSyncFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string CycleExceptions) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string SnapshotWriteFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string SseBroadcastFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string WorkspaceHeartbeatFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TurnMetricsSnapshotFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string OasExecutionErrors) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string EpisodeCreateFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string MemoryActivityEmitFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string SupervisorSweepFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TomlReconcileSweepFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolUsageFlushFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TurnTimeoutCommitted) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TurnErrorAfterTools) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TurnCleanupFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string CleanupTrackingFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string RuntimeSyncFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string LocalDiscoveryFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ThinkingPersistFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string CheckpointFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string MemoryWriteFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string WriteMetaCycleFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string AlertPersistFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string MetricsSseFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string DispatchEventFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string SessionCleanupFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ChatStoreFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ObservationQueryFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolUseFailure) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ConfigEnvParseFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ReceiptUnmappedDisposition) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string PostTurnWireinFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string MetaReadFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ApprovalQueueFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ProfileLoadFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string CompactAuditFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string FsFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string CrashPersistenceFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string GenerationLineageFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string KeepaliveSignalFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string MetaJsonFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolsOasFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string TurnUpUpdateFailures) |> int_of_float)
+ (Otel_metric_store.metric_total Keeper_metrics.(to_string ExecutionReceiptFailures) |> int_of_float)
+ (Otel_metric_store.metric_total Keeper_metrics.(to_string LlmBridgeFailures) |> int_of_float)
        + (Otel_metric_store.metric_total Keeper_metrics.(to_string ToolExecuteFailures) |> int_of_float)
      + (Otel_metric_store.metric_total Keeper_metrics.(to_string RolloverFailures) |> int_of_float)
      in
      let tool_suffix =
        if tool_failures > 0
        then Printf.sprintf " | TOOL-ERR: %d" tool_failures
        else ""
      in
      Printf.sprintf
        "KEEPERS: %d running / %d dead / %d other | GUARD: %d | \
         META-WRITE-ERR: %d%s"
        k_running
        k_dead
        k_other
        guard_violations
        write_meta_failures
        tool_suffix;
    ]

let () =
  Tool_misc.register_dashboard_handler (fun ~tool_name:tool_name_arg ~start_time ctx args ->
    let open Tool_result in
    let compact =
      match Json_util.assoc_member_opt "compact" args with
      | Some (`Bool b) -> b
      | _ -> false
    in
    let scope_arg =
      match Json_util.assoc_member_opt "scope" args with
      | Some (`String s) -> String.lowercase_ascii s
      | _ -> "all"
    in
    match scope_of_string_opt scope_arg with
    | None ->
        make_err
          ~tool_name:tool_name_arg
          ~class_:Workflow_rejection
          ~start_time
          (Printf.sprintf "Invalid dashboard scope '%s' (expected: %s)"
             scope_arg
             (String.concat " | " valid_scope_strings))
    | Some scope ->
        let output =
          if compact then generate_compact ~scope ctx.config
          else generate ~scope ctx.config
        in
        make_ok ~tool_name:tool_name_arg ~start_time ~data:(`String output) ()
  )


let force_link = ()
