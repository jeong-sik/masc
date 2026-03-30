(** Data loading functions for MASC TUI *)

open Masc_tui_types

(** Load keepers from .masc/keepers/ *)
let load_keepers (base_path : string) : keeper list =
  let keepers_dir = Filename.concat (Filename.concat base_path ".masc") "keepers" in
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
           let open Yojson.Safe.Util in
           let str key default = try json |> member key |> to_string with Type_error _ -> default in
           let int_ key default = try json |> member key |> to_int with Type_error _ -> default in
           let float_ key default = try json |> member key |> to_number with Type_error _ -> default in
           let bool_ key default = try json |> member key |> to_bool with Type_error _ -> default in
           let str_list key = try json |> member key |> to_list |> List.map to_string with Type_error _ -> [] in
           Some {
             k_name = str "name" (Filename.chop_suffix f ".json");
             k_goal = str "goal" "";
             k_short_goal = str "short_goal" "";
             k_soul_profile = str "soul_profile" "unknown";
             k_generation = int_ "generation" 0;
             k_active_model = str "active_model" "unknown";
             k_models = str_list "models";
             k_proactive_enabled = bool_ "proactive_enabled" false;
             k_initiative_enabled = bool_ "initiative_enabled" false;
             k_total_turns = int_ "total_turns" 0;
             k_total_tokens = int_ "total_tokens" 0;
             k_total_cost_usd = float_ "total_cost_usd" 0.0;
             k_last_turn_ts = str "last_turn_ts" "";
             k_compaction_count = int_ "compaction_count" 0;
             k_compaction_ratio_gate = float_ "compaction_ratio_gate" 0.5;
             k_scope_kind = str "scope_kind" "local";
             k_room_scope = str "room_scope" "current";
             k_trigger_mode = str "trigger_mode" "legacy";
             k_context_budget = int_ "context_budget" 0;
             k_handoff_threshold = float_ "handoff_threshold" 0.85;
             k_drift_enabled = bool_ "drift_enabled" false;
             k_verify = bool_ "verify" false;
             k_created_at = str "created_at" "";
             k_updated_at = str "updated_at" "";
           }
         with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Sys_error _ -> None
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
  try
    let json = Yojson.Safe.from_string line in
    let open Yojson.Safe.Util in
    let str key default = try json |> member key |> to_string with Type_error _ -> default in
    let int_ key default = try json |> member key |> to_int with Type_error _ -> default in
    let float_ key default = try json |> member key |> to_number with Type_error _ -> default in
    let bool_ key default = try json |> member key |> to_bool with Type_error _ -> default in
    let str_list key = try json |> member key |> to_list |> List.map to_string with Type_error _ -> [] in
    Some {
      le_ts = str "ts" "";
      le_channel = str "channel" "unknown";
      le_context_ratio = float_ "context_ratio" 0.0;
      le_context_tokens = int_ "context_tokens" 0;
      le_context_max = int_ "context_max" 0;
      le_message_count = int_ "message_count" 0;
      le_model_used = str "model_used" "";
      le_input_tokens = (try json |> member "usage" |> member "input_tokens" |> to_int with Type_error _ -> 0);
      le_output_tokens = (try json |> member "usage" |> member "output_tokens" |> to_int with Type_error _ -> 0);
      le_latency_ms = int_ "latency_ms" 0;
      le_cost_usd = float_ "cost_usd" 0.0;
      le_work_kind = str "work_kind" "";
      le_tools_used = str_list "tools_used";
      le_compacted = bool_ "compacted" false;
      le_goal_alignment = float_ "goal_alignment" 0.0;
      le_repetition_risk = float_ "repetition_risk" 0.0;
      le_guardrail_stop = bool_ "guardrail_stop" false;
    }
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

(** Find the most recent metrics file for a keeper *)
let find_metrics_files (base_path : string) (keeper_name : string) : string list =
  let metrics_dir = Filename.concat
    (Filename.concat
       (Filename.concat base_path ".masc")
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
  let masc_dir = Filename.concat base_path ".masc" in

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
             let open Yojson.Safe.Util in
             let name = json |> member "name" |> to_string in
             let status_val = json |> member "status" in
             let status = match status_val with
               | `List (s :: _) -> to_string s
               | `String s -> s
               | _ -> "unknown"
             in
             let current_task = json |> member "current_task" |> to_string_option in
             let last_seen = json |> member "last_seen" |> to_string in
             Some { name; status; current_task; last_seen }
           with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Sys_error _ -> None
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
             let open Yojson.Safe.Util in
             let id = json |> member "id" |> to_string in
             let title = json |> member "title" |> to_string in
             let status = json |> member "status" |> to_string in
             let priority = json |> member "priority" |> to_int_option |> Option.value ~default:3 in
             let claimed_by = json |> member "claimed_by" |> to_string_option in
             Some { id; title; status; priority; claimed_by }
           with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Sys_error _ -> None
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
