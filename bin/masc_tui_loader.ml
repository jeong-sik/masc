(** TUI data loading functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_http

let report path err =
  Printf.eprintf "[masc-tui] decode failed for %s: %s\n%!" path err

(** Load keepers from .masc/keepers/ *)
let load_keepers (base_path : string) : keeper list =
  let keepers_dir = Filename.concat (Filename.concat base_path Common.masc_dirname) "keepers" in
  if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir then
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter (fun f ->
         Filename.check_suffix f ".json"
         && not (String.contains f '.'))  (* This won't work, use different filter *)
    |> (fun _ ->
         (* Re-filter: only files that are exactly <name>.json, not <name>.reward-model.json *)
         Sys.readdir keepers_dir
         |> Array.to_list
         |> List.filter (fun f ->
              Filename.check_suffix f ".json"
              && (let base = Filename.chop_suffix f ".json" in
                  not (String.contains base '.'))))
    |> List.filter_map (fun f ->
         try
           let path = Filename.concat keepers_dir f in
           let json = Yojson.Safe.from_file path in
           match Tui_decode.decode_keeper ~filename:f json with
           | Ok keeper -> Some keeper
           | Error err ->
               report path err;
               None
         with Yojson.Json_error err ->
           report (Filename.concat keepers_dir f) ("invalid JSON: " ^ err);
           None
         | Sys_error err ->
           report (Filename.concat keepers_dir f) err;
           None
       )
    |> List.sort (fun a b -> String.compare a.k_name b.k_name)
  else []

(** Read the last N lines from a file (tail) *)
let read_last_lines path n =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        (* Read all lines then take last N -- simple for JSONL files < 1MB *)
        let lines = ref [] in
        (try while true do
           lines := input_line ic :: !lines
         done with End_of_file -> ());
        let all = List.rev !lines in
        let len = List.length all in
        if len <= n then all
        else
          List.filteri (fun i _ -> i >= len - n) all)
  with Sys_error _ -> []

(** Parse a single metrics JSONL line into a log_entry *)
let parse_log_entry (line : string) : log_entry option =
  match Tui_decode.parse_log_entry line with
  | Ok entry -> Some entry
  | Error err ->
      Printf.eprintf "[masc-tui] log decode failed: %s\n%!" err;
      None

(** Find the most recent metrics file for a keeper *)
let find_metrics_files (base_path : string) (keeper_name : string) : string list =
  let metrics_dir = Filename.concat
    (Filename.concat
       (Filename.concat base_path Common.masc_dirname)
       "keepers")
    (Filename.concat keeper_name "metrics") in
  if not (Sys.file_exists metrics_dir && Sys.is_directory metrics_dir) then []
  else begin
    (* List year-month directories, pick the most recent *)
    let months = Sys.readdir metrics_dir
      |> Array.to_list
      |> List.filter (fun d ->
           let full = Filename.concat metrics_dir d in
           Sys.is_directory full)
      |> List.sort (fun a b -> String.compare b a)  (* Reverse sort: most recent first *)
    in
    match months with
    | [] -> []
    | month :: _ ->
      let month_dir = Filename.concat metrics_dir month in
      Sys.readdir month_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort (fun a b -> String.compare b a)  (* Most recent first *)
      |> List.map (fun f -> Filename.concat month_dir f)
  end

(** Load log entries for the currently selected keeper *)
let load_keeper_logs (base_path : string) (keeper_name : string) (max_entries : int) : log_entry list =
  let files = find_metrics_files base_path keeper_name in
  let entries = ref [] in
  let remaining = ref max_entries in
  List.iter (fun path ->
    if !remaining > 0 then begin
      let lines = read_last_lines path !remaining in
      let parsed = List.filter_map parse_log_entry lines in
      entries := parsed @ !entries;
      remaining := !remaining - List.length parsed
    end
  ) files;
  (* Return in chronological order, limited to max_entries *)
  let all = List.rev !entries in
  let len = List.length all in
  if len <= max_entries then all
  else List.filteri (fun i _ -> i >= len - max_entries) all

(** Load live context status from the latest metrics entry *)
let load_live_context (state : state) (base_path : string) (keeper_name : string) =
  let files = find_metrics_files base_path keeper_name in
  match files with
  | [] ->
    state.live_context_ratio <- 0.0;
    state.live_context_tokens <- 0;
    state.live_context_max <- 0;
    state.live_message_count <- 0
  | latest_file :: _ ->
    (* Read just the last line *)
    let lines = read_last_lines latest_file 1 in
    (match lines with
     | [] ->
       state.live_context_ratio <- 0.0;
       state.live_context_tokens <- 0;
       state.live_context_max <- 0;
       state.live_message_count <- 0
     | line :: _ ->
       match parse_log_entry line with
       | None ->
         state.live_context_ratio <- 0.0;
         state.live_context_tokens <- 0;
         state.live_context_max <- 0;
         state.live_message_count <- 0
       | Some e ->
         state.live_context_ratio <- e.le_context_ratio;
         state.live_context_tokens <- e.le_context_tokens;
         state.live_context_max <- e.le_context_max;
         state.live_message_count <- e.le_message_count)

(** Load state from .masc directory *)
let load_from_masc_dir (state : state) (base_path : string) =
  let masc_dir = Filename.concat base_path Common.masc_dirname in

  (* Load agents *)
  let agents_dir = Filename.concat masc_dir "agents" in
  state.agents <- (
    if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
      Sys.readdir agents_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
           try
             let path = Filename.concat agents_dir f in
             let json = Yojson.Safe.from_file path in
             match Tui_decode.decode_agent json with
             | Ok agent -> Some agent
             | Error err ->
                 report path err;
                 None
           with Yojson.Json_error err ->
             report (Filename.concat agents_dir f) ("invalid JSON: " ^ err);
             None
           | Sys_error err ->
             report (Filename.concat agents_dir f) err;
             None
         )
    else []
  );

  (* Load tasks *)
  let tasks_dir = Filename.concat masc_dir "tasks" in
  state.tasks <- (
    if Sys.file_exists tasks_dir && Sys.is_directory tasks_dir then
      Sys.readdir tasks_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
           try
             let path = Filename.concat tasks_dir f in
             let json = Yojson.Safe.from_file path in
             match Tui_decode.decode_task json with
             | Ok task -> Some task
             | Error err ->
                 report path err;
                 None
           with Yojson.Json_error err ->
             report (Filename.concat tasks_dir f) ("invalid JSON: " ^ err);
             None
           | Sys_error err ->
             report (Filename.concat tasks_dir f) err;
             None
         )
      |> List.sort (fun a b -> compare a.priority b.priority)
    else []
  );

  (* Load keepers *)
  state.keepers <- load_keepers base_path;

  (* Clamp cursor if keepers changed *)
  if state.keeper_cursor >= List.length state.keepers then
    state.keeper_cursor <- max 0 (List.length state.keepers - 1);

  (* Load live context for selected keeper *)
  if state.keeper_cursor < List.length state.keepers then begin
    let k = List.nth state.keepers state.keeper_cursor in
    load_live_context state base_path k.k_name
  end;

  state.last_refresh <- Unix.gettimeofday ()

(** Add event to the event log *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  state.events <- ev :: (List.filteri (fun i _ -> i < 10) state.events)

(** HTTP JSON decoding helpers. These intentionally fail closed for the TUI
    dashboard surfaces: an empty list means the API really returned an empty
    list, not that a malformed payload was silently dropped. *)
let ( let* ) = Result.bind

let decode_attention_severity raw =
  match String.lowercase_ascii (String.trim raw) with
  | "critical" -> Ok Attention_critical
  | "bad" -> Ok Attention_bad
  | "warn" | "warning" -> Ok Attention_warning
  | "info" -> Ok Attention_info
  | other ->
      Error
        (Printf.sprintf
           "unknown attention severity %S (normalized %S)"
           raw
           other)

let decode_workspace_health raw =
  match String.lowercase_ascii (String.trim raw) with
  | "critical" -> Ok Workspace_health_critical
  | "bad" -> Ok Workspace_health_bad
  | "risk" -> Ok Workspace_health_risk
  | "warn" | "warning" | "watch" -> Ok Workspace_health_warning
  | "degraded" | "interrupted" -> Ok Workspace_health_degraded
  | "initializing" -> Ok Workspace_health_initializing
  | "ok" | "good" | "healthy" -> Ok Workspace_health_ok
  | "unknown" -> Ok Workspace_health_unknown
  | other ->
      Error
        (Printf.sprintf
           "unknown workspace health %S (normalized %S)"
           raw
           other)

let decode_attention_item json =
  let* ai_kind = required_string_field json "kind" in
  let* raw_severity = required_string_field json "severity" in
  let* ai_severity = decode_attention_severity raw_severity in
  let* ai_summary = required_string_field json "summary" in
  let* ai_target_type = required_string_field json "target_type" in
  let* ai_target_id = optional_string_field json "target_id" in
  Ok { ai_kind; ai_severity; ai_summary; ai_target_type; ai_target_id }

let decode_attention_items json_list =
  decode_list "attention_items" decode_attention_item json_list

let decode_approval_item json =
  let* ap_token = required_string_field json "confirm_token" in
  let* ap_actor = required_string_field json "actor" in
  let* ap_action_type = required_string_field json "action_type" in
  let* ap_target_type = required_string_field json "target_type" in
  let* ap_target_id = optional_string_field json "target_id" in
  let* ap_delegated_tool = required_string_field json "delegated_tool" in
  let ap_summary =
    Printf.sprintf "%s on %s (%s)" ap_action_type ap_target_type
      ap_delegated_tool
  in
  Ok
    {
      ap_token;
      ap_actor;
      ap_action_type;
      ap_target_type;
      ap_target_id;
      ap_delegated_tool;
      ap_summary;
    }

let decode_approval_items json_list =
  decode_list "pending_confirms" decode_approval_item json_list

let decode_board_post ?(require_body = false) json =
  let* bp_id = required_string_field json "id" in
  let* bp_author = required_string_field json "author" in
  let* bp_title = required_string_field json "title" in
  let* bp_body =
    if require_body then required_body_field json else optional_body_field json
  in
  let* bp_votes = required_int_field json "votes" in
  let* bp_comment_count = required_int_field json "comment_count" in
  let* bp_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  Ok
    {
      bp_id;
      bp_author;
      bp_title;
      bp_body;
      bp_votes;
      bp_comment_count;
      bp_created_at;
    }

let decode_board_posts json_list =
  decode_list "posts" decode_board_post json_list

let decode_board_comment json =
  let* bc_id = required_string_field json "id" in
  let* bc_author = required_string_field json "author" in
  let* bc_content = required_string_field json "content" in
  let* bc_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  Ok { bc_id; bc_author; bc_content; bc_created_at }

let decode_board_comments json_list =
  decode_list "comments" decode_board_comment json_list

(** Load board post list from /api/v1/board *)
let load_board_list ~(host : string) ~(port : int) :
    (board_post list, string) result =
  match fetch_board ~host ~port with
  | Error err -> Error ("board load failed: " ^ err)
  | Ok json ->
      let* posts = required_list_field json "posts" in
      decode_board_posts posts

(** Load board post detail from /api/v1/board/<postId> *)
let load_board_post ~(host : string) ~(port : int) ~(post_id : string) :
    (board_post * board_comment list, string) result =
  match fetch_board_post ~host ~port ~post_id with
  | Error err -> Error (Printf.sprintf "board post load failed: %s" err)
  | Ok json ->
      let post_json =
        match Yojson.Safe.Util.member "post" json with
        | `Null -> json
        | value -> value
      in
      let* post = decode_board_post ~require_body:true post_json in
      let* comments_json = optional_list_field json "comments" in
      let* comments = decode_board_comments comments_json in
      Ok (post, comments)

(** Load overview snapshot from /api/v1/dashboard/briefing *)
let load_overview ~(host : string) ~(port : int) :
    (overview_snapshot, string) result =
  match fetch_dashboard_briefing ~host ~port with
  | Error err -> Error ("overview load failed: " ^ err)
  | Ok json ->
      let* summary = required_object_field json "summary" in
      let* command_focus = optional_object_field json "command_focus" in
      let* incidents =
        let* items = optional_list_field json "incidents" in
        decode_attention_items items
      in
      let* attention_queue =
        let* items = optional_list_field json "attention_queue" in
        decode_attention_items items
      in
      let* attention_items =
        let* items = optional_list_field json "attention_items" in
        decode_attention_items items
      in
      let* pending_confirms =
        let* operator_targets = optional_object_field json "operator_targets" in
        match operator_targets with
        | None -> Ok []
        | Some operator_targets ->
            let* items = optional_list_field operator_targets "pending_confirms" in
            decode_approval_items items
      in
      let* agent_briefs = optional_list_field json "agent_briefs" in
      let* top_attention =
        let fallback =
          match incidents with
          | first :: _ -> Some first
          | [] -> None
        in
        match command_focus with
        | None -> Ok fallback
        | Some command_focus -> (
            match Yojson.Safe.Util.member "top_attention" command_focus with
            | `Null -> Ok fallback
            | value ->
                Result.map (fun item -> Some item) (decode_attention_item value))
      in
      let* ov_workspace_health =
        let* workspace_health = required_string_field summary "workspace_health" in
        decode_workspace_health workspace_health
      in
      let* ov_cluster = required_string_field summary "cluster" in
      let* ov_project = required_string_field summary "project" in
      let* ov_active_agents =
        int_field_or summary "active_agents" ~default:(List.length agent_briefs)
      in
      let* ov_pending_approvals =
        match command_focus with
        | Some command_focus ->
            int_field_or command_focus "pending_approvals"
              ~default:(List.length pending_confirms)
        | None ->
            int_field_or summary "pending_approvals"
              ~default:(List.length pending_confirms)
      in
      let* ov_incident_count =
        int_field_or summary "incident_count" ~default:(List.length incidents)
      in
      let* ov_generated_at = required_string_field json "generated_at" in
      Ok
        {
          ov_workspace_health;
          ov_cluster;
          ov_project;
          ov_active_agents;
          ov_pending_approvals;
          ov_incident_count;
          ov_attention_items = incidents @ attention_queue @ attention_items;
          ov_top_attention = top_attention;
          ov_pending_confirms = pending_confirms;
          ov_generated_at;
        }

let decode_planning_goal json =
  let* pg_id = required_string_field json "id" in
  let* pg_title = required_string_field json "title" in
  let* raw_status = required_string_field json "status" in
  let* pg_status =
    match String.lowercase_ascii raw_status with
    | "active" -> Ok Planning_goal_active
    | "paused" -> Ok Planning_goal_paused
    | "done" -> Ok Planning_goal_done
    | "dropped" -> Ok Planning_goal_dropped
    | other ->
        Error
          (Printf.sprintf
             "unknown planning goal status %S (normalized %S)"
             raw_status
             other)
  in
  let* pg_phase = required_string_field json "phase" in
  let* pg_priority = required_int_field json "priority" in
  let* pg_due_date = optional_string_field json "due_date" in
  let* pg_parent_goal_id = optional_string_field json "parent_goal_id" in
  let* pg_metric = optional_string_field json "metric" in
  let* pg_target_value = optional_string_field json "target_value" in
  Ok
    {
      pg_id;
      pg_title;
      pg_status;
      pg_phase;
      pg_priority;
      pg_due_date;
      pg_parent_goal_id;
      pg_metric;
      pg_target_value;
    }

let decode_planning_goals json_list =
  decode_list "goals" decode_planning_goal json_list

let decode_planning_rollup json =
  let* pr_active = required_int_field json "active_count" in
  let* pr_paused = required_int_field json "paused_count" in
  let* pr_done = required_int_field json "done_count" in
  let* pr_dropped = required_int_field json "dropped_count" in
  Ok { pr_active; pr_paused; pr_done; pr_dropped }

let decode_planning_backlog json =
  let* pb_todo = required_int_field json "todo" in
  let* pb_claimed = required_int_field json "claimed" in
  let* pb_running = required_int_any_field json [ "in_progress"; "running" ] in
  let* pb_done = required_int_field json "done" in
  let* pb_cancelled = required_int_field json "cancelled" in
  Ok { pb_todo; pb_claimed; pb_running; pb_done; pb_cancelled }

(** Load planning snapshot from /api/v1/dashboard/planning *)
let load_planning ~(host : string) ~(port : int) :
    (planning_snapshot, string) result =
  match fetch_dashboard_planning ~host ~port with
  | Error err -> Error ("planning load failed: " ^ err)
  | Ok json ->
      let* goals_json = required_list_field json "goals" in
      let* goals = decode_planning_goals goals_json in
      let* rollup_json = required_object_field json "rollup" in
      let* rollup = decode_planning_rollup rollup_json in
      let* backlog_json = required_object_field json "task_backlog" in
      let* backlog = decode_planning_backlog backlog_json in
      let* generated_at = required_string_field json "generated_at" in
      Ok
        {
          pl_goals = goals;
          pl_rollup = rollup;
          pl_backlog = backlog;
          pl_generated_at = generated_at;
        }
