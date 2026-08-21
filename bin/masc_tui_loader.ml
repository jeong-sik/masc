(** TUI data loading functions — split from masc_tui.ml (#3808) *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_types_support = Masc.Keeper_types_support
module Keeper_types_profile = Masc.Keeper_types_profile

open Masc_tui_types
open Tui_decode
open Masc_tui_http

let report path err =
  Printf.eprintf "[masc-tui] decode failed for %s: %s\n%!" path err

let summarize_errors label errors =
  match List.rev errors with
  | [] -> None
  | first :: rest ->
      let suffix =
        match rest with
        | [] -> ""
        | _ -> Printf.sprintf " (+%d more)" (List.length rest)
      in
      Some (Printf.sprintf "%s: %s%s" label first suffix)

(** Load keepers through the canonical metadata classifier and typed store.
    The classifier preserves valid dotted names and excludes sidecars. *)
let load_keepers (base_path : string) : keeper list * string option =
  let config = Workspace_core.default_config base_path in
  match Keeper_meta_store.persisted_keeper_names_result config with
  | Error err ->
      report (Keeper_types_profile.keeper_dir config) err;
      [], Some ("keeper metadata unavailable: " ^ err)
  | Ok names ->
      let keepers, errors =
        List.fold_left
          (fun (keepers, errors) name ->
             let path = Keeper_types_profile.keeper_meta_path config name in
             match Keeper_meta_store.read_meta config name with
             | Ok (Some meta) ->
                 Tui_decode.keeper_of_meta meta :: keepers, errors
             | Ok None ->
                 let err = "metadata disappeared during refresh" in
                 report path err;
                 keepers, (Printf.sprintf "%s: %s" name err :: errors)
             | Error err ->
                 report path err;
                 keepers, (Printf.sprintf "%s: %s" name err :: errors))
          ([], []) names
      in
      ( List.sort (fun a b -> String.compare a.k_name b.k_name) keepers
      , summarize_errors "keeper metadata read failed" errors )

(** Load active tasks from the canonical workspace backlog. Terminal tasks
    remain available in Planning rollups but do not occupy the Overview list. *)
let load_active_tasks (base_path : string) : task list * string option =
  let config = Workspace_core.default_config base_path in
  let path = Workspace_backlog.backlog_path config in
  match Workspace_backlog.read_backlog_observation_with_source_r config with
  | Error err ->
      report path err;
      [], Some ("task backlog unavailable: " ^ err)
  | Ok observation ->
      let recovery_error =
        match observation.recovered_from with
        | None -> None
        | Some recovery ->
            report path recovery.primary_error;
            Some ("task backlog recovered from backup: " ^ recovery.primary_error)
      in
      ( Tui_decode.active_tasks_of_domain observation.observed_backlog.tasks
      , recovery_error )

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
  let config = Workspace_core.default_config base_path in
  let metrics_dir = Keeper_types_support.keeper_metrics_dir config keeper_name in
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

  (* Load tasks from their single durable source. *)
  let tasks, tasks_error = load_active_tasks base_path in
  state.tasks <- tasks;
  state.tasks_error <- tasks_error;

  (* Preserve the selected Keeper by identity across sorted roster refreshes. *)
  let selected_keeper_name =
    List.nth_opt state.keepers state.keeper_cursor
    |> Option.map (fun keeper -> keeper.k_name)
  in

  (* Load keepers *)
  let keepers, keepers_error = load_keepers base_path in
  state.keepers <- keepers;
  state.keepers_error <- keepers_error;

  (* Re-find the same identity, or clamp only when that Keeper disappeared. *)
  state.keeper_cursor <-
    (match selected_keeper_name with
     | Some keeper_name ->
         (match
            List.find_index
              (fun keeper -> String.equal keeper.k_name keeper_name)
              state.keepers
          with
          | Some index -> index
          | None -> min state.keeper_cursor (max 0 (List.length state.keepers - 1)))
     | None -> min state.keeper_cursor (max 0 (List.length state.keepers - 1)));

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

(** Load the actor-scoped pending confirmation envelope from the operator
    surface. Missing or malformed envelopes remain explicit errors. *)
let load_approvals ~(host : string) ~(port : int) :
    (approval_snapshot, string) result =
  match fetch_operator_snapshot ~host ~port with
  | Error err -> Error ("approvals load failed: " ^ err)
  | Ok json -> Masc_tui_operator_projection.decode_snapshot json

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
          ov_incident_count;
          ov_attention_items = incidents @ attention_queue @ attention_items;
          ov_top_attention = top_attention;
          ov_generated_at;
        }

(** Load planning snapshot from /api/v1/dashboard/planning *)
let load_planning ~(host : string) ~(port : int) :
    (planning_snapshot, string) result =
  match fetch_dashboard_planning ~host ~port with
  | Error err -> Error ("planning load failed: " ^ err)
  | Ok json -> Tui_decode.decode_planning_snapshot json
