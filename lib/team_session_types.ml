(** Team session types for long-running collaborative orchestration. *)

open Yojson.Safe.Util

type session_status =
  | Running
  | Paused
  | Completed
  | Interrupted
  | Failed

type execution_scope =
  | Observe_only
  | Limited_code_change

type report_format =
  | Markdown
  | Json

type session = {
  session_id : string;
  goal : string;
  created_by : string;
  room_id : string;
  status : session_status;
  duration_seconds : int;
  execution_scope : execution_scope;
  checkpoint_interval_sec : int;
  min_agents : int;
  auto_resume : bool;
  report_formats : report_format list;
  agent_names : string list;
  baseline_done_counts : (string * int) list;
  started_at : float;
  planned_end_at : float;
  stopped_at : float option;
  last_checkpoint_at : float option;
  last_event_at : float option;
  stop_reason : string option;
  generated_report : bool;
  artifacts_dir : string;
  created_at_iso : string;
  updated_at_iso : string;
}

type event_entry = {
  ts : float;
  ts_iso : string;
  event_type : string;
  detail : Yojson.Safe.t;
}

type checkpoint = {
  ts : float;
  ts_iso : string;
  status : session_status;
  elapsed_sec : int;
  remaining_sec : int;
  progress_pct : float;
  done_delta_total : int;
  done_delta_by_agent : (string * int) list;
  active_agents : string list;
}

let status_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Completed -> "completed"
  | Interrupted -> "interrupted"
  | Failed -> "failed"

let status_of_string = function
  | "running" -> Running
  | "paused" -> Paused
  | "completed" -> Completed
  | "interrupted" -> Interrupted
  | "failed" -> Failed
  | _ -> Failed

let execution_scope_to_string = function
  | Observe_only -> "observe_only"
  | Limited_code_change -> "limited_code_change"

let execution_scope_of_string = function
  | "limited_code_change" -> Limited_code_change
  | _ -> Observe_only

let report_format_to_string = function
  | Markdown -> "markdown"
  | Json -> "json"

let report_format_of_string = function
  | "markdown" -> Some Markdown
  | "json" -> Some Json
  | _ -> None

let report_formats_of_strings xs =
  let rec dedup acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if List.mem x acc then dedup acc rest else dedup (x :: acc) rest
  in
  xs
  |> List.filter_map (fun s -> report_format_of_string (String.lowercase_ascii (String.trim s)))
  |> dedup []

let assoc_int_to_json pairs =
  `Assoc (List.map (fun (k, v) -> (k, `Int v)) pairs)

let assoc_int_of_json json =
  match json with
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `Int n -> Some (k, n)
          | `Intlit s -> (
              try Some (k, int_of_string s) with _ -> None)
          | _ -> None)
        fields
  | _ -> []

let session_to_yojson (s : session) =
  `Assoc
    [
      ("session_id", `String s.session_id);
      ("goal", `String s.goal);
      ("created_by", `String s.created_by);
      ("room_id", `String s.room_id);
      ("status", `String (status_to_string s.status));
      ("duration_seconds", `Int s.duration_seconds);
      ("execution_scope", `String (execution_scope_to_string s.execution_scope));
      ("checkpoint_interval_sec", `Int s.checkpoint_interval_sec);
      ("min_agents", `Int s.min_agents);
      ("auto_resume", `Bool s.auto_resume);
      ("report_formats", `List (List.map (fun f -> `String (report_format_to_string f)) s.report_formats));
      ("agent_names", `List (List.map (fun a -> `String a) s.agent_names));
      ("baseline_done_counts", assoc_int_to_json s.baseline_done_counts);
      ("started_at", `Float s.started_at);
      ("planned_end_at", `Float s.planned_end_at);
      ("stopped_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.stopped_at);
      ("last_checkpoint_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.last_checkpoint_at);
      ("last_event_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.last_event_at);
      ("stop_reason", Option.fold ~none:`Null ~some:(fun v -> `String v) s.stop_reason);
      ("generated_report", `Bool s.generated_report);
      ("artifacts_dir", `String s.artifacts_dir);
      ("created_at_iso", `String s.created_at_iso);
      ("updated_at_iso", `String s.updated_at_iso);
    ]

let session_of_yojson json =
  try
    let get_int_default key default =
      match member key json with
      | `Int n -> n
      | `Intlit s -> (try int_of_string s with _ -> default)
      | _ -> default
    in
    let get_float_default key default =
      match member key json with
      | `Float v -> v
      | `Int n -> float_of_int n
      | `Intlit s -> (try float_of_string s with _ -> default)
      | _ -> default
    in
    let started_at = get_float_default "started_at" (Time_compat.now ()) in
    let duration_seconds = get_int_default "duration_seconds" 3600 in
    let default_end = started_at +. float_of_int duration_seconds in
    Some
      {
        session_id = json |> member "session_id" |> to_string;
        goal = json |> member "goal" |> to_string;
        created_by = json |> member "created_by" |> to_string_option |> Option.value ~default:"unknown";
        room_id = json |> member "room_id" |> to_string_option |> Option.value ~default:"default";
        status = json |> member "status" |> to_string_option |> Option.value ~default:"failed" |> status_of_string;
        duration_seconds;
        execution_scope =
          json |> member "execution_scope" |> to_string_option |> Option.value ~default:"observe_only"
          |> execution_scope_of_string;
        checkpoint_interval_sec = get_int_default "checkpoint_interval_sec" 60;
        min_agents = get_int_default "min_agents" 2;
        auto_resume = json |> member "auto_resume" |> to_bool_option |> Option.value ~default:true;
        report_formats =
          (match member "report_formats" json with
           | `List xs ->
               xs
               |> List.filter_map (function `String s -> Some s | _ -> None)
               |> report_formats_of_strings
           | _ -> [])
          |> (fun xs -> if xs = [] then [Markdown; Json] else xs);
        agent_names =
          (match member "agent_names" json with
           | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> []);
        baseline_done_counts = assoc_int_of_json (member "baseline_done_counts" json);
        started_at;
        planned_end_at = get_float_default "planned_end_at" default_end;
        stopped_at = json |> member "stopped_at" |> to_float_option;
        last_checkpoint_at = json |> member "last_checkpoint_at" |> to_float_option;
        last_event_at = json |> member "last_event_at" |> to_float_option;
        stop_reason = json |> member "stop_reason" |> to_string_option;
        generated_report = json |> member "generated_report" |> to_bool_option |> Option.value ~default:false;
        artifacts_dir = json |> member "artifacts_dir" |> to_string_option |> Option.value ~default:"";
        created_at_iso = json |> member "created_at_iso" |> to_string_option |> Option.value ~default:(Types.now_iso ());
        updated_at_iso = json |> member "updated_at_iso" |> to_string_option |> Option.value ~default:(Types.now_iso ());
      }
  with _ -> None

let event_entry_to_yojson (e : event_entry) =
  `Assoc
    [
      ("ts", `Float e.ts);
      ("ts_iso", `String e.ts_iso);
      ("event_type", `String e.event_type);
      ("detail", e.detail);
    ]

let checkpoint_to_yojson (c : checkpoint) =
  `Assoc
    [
      ("ts", `Float c.ts);
      ("ts_iso", `String c.ts_iso);
      ("status", `String (status_to_string c.status));
      ("elapsed_sec", `Int c.elapsed_sec);
      ("remaining_sec", `Int c.remaining_sec);
      ("progress_pct", `Float c.progress_pct);
      ("done_delta_total", `Int c.done_delta_total);
      ("done_delta_by_agent", assoc_int_to_json c.done_delta_by_agent);
      ("active_agents", `List (List.map (fun a -> `String a) c.active_agents));
    ]
