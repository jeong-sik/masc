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

(** Overview JSON decoding helpers *)
let string_field_default json key default =
  try Yojson.Safe.Util.to_string (Yojson.Safe.Util.member key json) with _ -> default

let int_field_default json key default =
  try Yojson.Safe.Util.to_int (Yojson.Safe.Util.member key json) with _ -> default

let decode_attention_item json =
  try
    Some {
      ai_kind = string_field_default json "kind" "-";
      ai_severity = string_field_default json "severity" "info";
      ai_summary = string_field_default json "summary" "-";
      ai_target_type = string_field_default json "target_type" "-";
      ai_target_id =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "target_id" json))
         with _ -> None);
    }
  with _ -> None

let decode_attention_items json_list =
  List.filter_map decode_attention_item json_list

let decode_approval_item json =
  try
    let token =
      try Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "confirm_token" json)
      with _ ->
        Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "token" json)
    in
    Some {
      ap_token = token;
      ap_actor = string_field_default json "actor" "-";
      ap_action_type = string_field_default json "action_type" "-";
      ap_target_type = string_field_default json "target_type" "-";
      ap_target_id =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "target_id" json))
         with _ -> None);
      ap_delegated_tool = string_field_default json "delegated_tool" "-";
      ap_summary =
        let action = string_field_default json "action_type" "-" in
        let target = string_field_default json "target_type" "-" in
        let tool = string_field_default json "delegated_tool" "-" in
        Printf.sprintf "%s on %s (%s)" action target tool;
    }
  with _ -> None

let decode_approval_items json_list =
  List.filter_map decode_approval_item json_list

let decode_board_post json =
  try
    let id = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "id" json) in
    let author = string_field_default json "author" "-" in
    let title = string_field_default json "title" "-" in
    let body =
      try Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "body" json)
      with _ ->
        (try Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "content" json)
         with _ -> "")
    in
    Some {
      bp_id = id;
      bp_author = author;
      bp_title = title;
      bp_body = body;
      bp_votes = int_field_default json "votes" 0;
      bp_comment_count = int_field_default json "comment_count" 0;
      bp_created_at = string_field_default json "created_at" "-";
    }
  with _ -> None

let decode_board_posts json_list =
  List.filter_map decode_board_post json_list

let decode_board_comment json =
  try
    let id = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "id" json) in
    let author = string_field_default json "author" "-" in
    let content = string_field_default json "content" "" in
    Some {
      bc_id = id;
      bc_author = author;
      bc_content = content;
      bc_created_at = string_field_default json "created_at" "-";
    }
  with _ -> None

let decode_board_comments json_list =
  List.filter_map decode_board_comment json_list

(** Load board post list from /api/v1/board *)
let load_board_list ~(host : string) ~(port : int) : board_post list =
  match fetch_board ~host ~port with
  | Error err ->
      Printf.eprintf "[masc-tui] board load failed: %s\n%!" err;
      []
  | Ok json ->
      try decode_board_posts (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "posts" json))
      with exn ->
        Printf.eprintf "[masc-tui] board decode failed: %s\n%!" (Printexc.to_string exn);
        []

(** Load board post detail from /api/v1/board/<postId> *)
let load_board_post ~(host : string) ~(port : int) ~(post_id : string) : (board_post * board_comment list) option =
  match fetch_board_post ~host ~port ~post_id with
  | Error err ->
      Printf.eprintf "[masc-tui] board post load failed: %s\n%!" err;
      None
  | Ok json ->
      try
        let post = decode_board_post (Yojson.Safe.Util.member "post" json) in
        let comments = decode_board_comments (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "comments" json)) in
        match post with
        | None -> None
        | Some p -> Some (p, comments)
      with exn ->
        Printf.eprintf "[masc-tui] board post decode failed: %s\n%!" (Printexc.to_string exn);
        None

(** Load overview snapshot from /api/v1/dashboard/briefing *)
let load_overview ~(host : string) ~(port : int) : overview_snapshot option =
  match fetch_dashboard_briefing ~host ~port with
  | Error err ->
      Printf.eprintf "[masc-tui] overview load failed: %s\n%!" err;
      None
  | Ok json ->
      try
        let summary = Yojson.Safe.Util.member "summary" json in
        let top_attention =
          match decode_attention_item (Yojson.Safe.Util.member "top_attention" summary) with
          | Some x -> Some x
          | None -> None
        in
        let incidents =
          try decode_attention_items (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "incidents" json))
          with _ -> []
        in
        let attention_queue =
          try decode_attention_items (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "attention_queue" json))
          with _ -> []
        in
        let attention_items =
          try decode_attention_items (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "attention_items" json))
          with _ -> []
        in
        let pending_confirms =
          try
            let operator_targets = Yojson.Safe.Util.member "operator_targets" json in
            decode_approval_items (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "pending_confirms" operator_targets))
          with _ -> []
        in
        Some {
          ov_workspace_health = string_field_default summary "workspace_health" "-";
          ov_cluster = string_field_default summary "cluster" "-";
          ov_project = string_field_default summary "project" "-";
          ov_active_agents = int_field_default summary "active_agents" 0;
          ov_pending_approvals = int_field_default summary "pending_approvals" 0;
          ov_incident_count = int_field_default summary "incident_count" 0;
          ov_attention_items = incidents @ attention_queue @ attention_items;
          ov_top_attention = top_attention;
          ov_pending_confirms = pending_confirms;
          ov_generated_at = string_field_default json "generated_at" "-";
        }
      with exn ->
        Printf.eprintf "[masc-tui] overview decode failed: %s\n%!" (Printexc.to_string exn);
        None

let decode_planning_goal json =
  try
    let id = Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "id" json) in
    Some {
      pg_id = id;
      pg_title = string_field_default json "title" "-";
      pg_status = string_field_default json "status" "active";
      pg_phase = string_field_default json "phase" "executing";
      pg_priority = int_field_default json "priority" 3;
      pg_due_date =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "due_date" json))
         with _ -> None);
      pg_parent_goal_id =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "parent_goal_id" json))
         with _ -> None);
      pg_metric =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "metric" json))
         with _ -> None);
      pg_target_value =
        (try Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "target_value" json))
         with _ -> None);
    }
  with _ -> None

let decode_planning_goals json_list =
  List.filter_map decode_planning_goal json_list

let decode_planning_rollup json =
  {
    pr_active = int_field_default json "active_count" 0;
    pr_paused = int_field_default json "paused_count" 0;
    pr_done = int_field_default json "done_count" 0;
    pr_dropped = int_field_default json "dropped_count" 0;
  }

let decode_planning_backlog json =
  {
    pb_todo = int_field_default json "todo" 0;
    pb_claimed = int_field_default json "claimed" 0;
    pb_running = int_field_default json "running" 0;
    pb_done = int_field_default json "done" 0;
    pb_cancelled = int_field_default json "cancelled" 0;
  }

(** Load planning snapshot from /api/v1/dashboard/planning *)
let load_planning ~(host : string) ~(port : int) : planning_snapshot option =
  match fetch_dashboard_planning ~host ~port with
  | Error err ->
      Printf.eprintf "[masc-tui] planning load failed: %s\n%!" err;
      None
  | Ok json ->
      try
        let goals =
          try decode_planning_goals (Yojson.Safe.Util.to_list (Yojson.Safe.Util.member "goals" json))
          with _ -> []
        in
        let rollup = decode_planning_rollup (Yojson.Safe.Util.member "rollup" json) in
        let backlog = decode_planning_backlog (Yojson.Safe.Util.member "task_backlog" json) in
        Some {
          pl_goals = goals;
          pl_rollup = rollup;
          pl_backlog = backlog;
          pl_generated_at = string_field_default json "generated_at" "-";
        }
      with exn ->
        Printf.eprintf "[masc-tui] planning decode failed: %s\n%!" (Printexc.to_string exn);
        None
