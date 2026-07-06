type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
  read_errors : Yojson.Safe.t list;
}

type turn_span_stat = {
  interaction_count : int;
  first_ts : float option;
  latest_ts : float option;
  read_errors : Yojson.Safe.t list;
}

let seconds_per_hour = Masc_time_constants.hour
let persistent_turn_window_hours = 24.0
let recent_turn_max_age_hours = 24.0
let decision_tail_max_bytes = 512 * 1024
let decision_tail_max_lines = 5000

let empty_scheduled_stat =
  {
    decision_count = 0;
    latest_ts = None;
    latest_ts_unix = None;
    failure_count = 0;
    read_errors = [];
  }

let empty_turn_span_stat =
  { interaction_count = 0; first_ts = None; latest_ts = None; read_errors = [] }

let decision_log_read_error_to_json ~keeper_name ~path ?line_index message =
  let fields =
    [ "source", `String "dashboard_keeper_decision_log_jsonl"
    ; "keeper", `String keeper_name
    ; "path", `String path
    ; "message", `String message
    ]
  in
  `Assoc
    (match line_index with
     | Some index -> ("line_index", `Int index) :: fields
     | None -> fields)

let fold_keeper_decision_log_with_read_errors ~config keeper_name ~init ~f =
  let path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then init, []
  else
    let raw_rows =
      match
        Keeper_memory.read_file_tail_lines_result path
          ~max_bytes:decision_tail_max_bytes
          ~max_lines:decision_tail_max_lines
      with
      | Ok lines -> List.mapi (fun line_index line -> line_index, Ok line) lines
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"dashboard_decision_log_proof" path exn_class;
          [
            ( 0,
              Error
                (decision_log_read_error_to_json
                   ~keeper_name
                   ~path
                   (Printexc.to_string exn_class)) );
          ]
    in
    raw_rows
    |> List.fold_left
         (fun (acc, read_errors) item ->
           match item with
           | _, Error error -> acc, error :: read_errors
           | line_index, Ok line ->
               let line = String.trim line in
               if line = "" then acc, read_errors
               else
                 match Yojson.Safe.from_string line with
                 | exception Yojson.Json_error message ->
                     ( acc
                     , decision_log_read_error_to_json
                         ~keeper_name
                         ~path
                         ~line_index
                         message
                       :: read_errors )
                 | json -> f acc json, read_errors)
         (init, [])
    |> fun (stat, read_errors) -> stat, List.rev read_errors

let fold_keeper_decision_log ~config keeper_name ~init ~f =
  fst (fold_keeper_decision_log_with_read_errors ~config keeper_name ~init ~f)

let decision_ts_unix json =
  match Safe_ops.json_float_opt "ts_unix" json with
  | Some ts when ts > 0.0 -> Some ts
  | _ ->
    (match Safe_ops.json_string_opt "ts" json with
     | Some ts -> Masc_domain.parse_iso8601_opt ts
     | None -> None)

let scheduled_success json =
  Safe_ops.json_string_opt "outcome" json = Some "success"

let update_scheduled_latest stat json =
  match decision_ts_unix json with
  | None -> stat
  | Some ts ->
    (match stat.latest_ts_unix with
     | Some previous when previous >= ts -> stat
     | _ ->
       {
         stat with
         latest_ts_unix = Some ts;
         latest_ts = Some (Masc_domain.iso8601_of_unix_seconds ts);
       })

let scheduled_stats ~config keeper_name =
  let stat, read_errors =
    fold_keeper_decision_log_with_read_errors ~config keeper_name
    ~init:empty_scheduled_stat
    ~f:(fun acc json ->
      match Safe_ops.json_string_opt "channel" json with
      | Some "scheduled_autonomous" ->
        if scheduled_success json then
          update_scheduled_latest
            { acc with decision_count = acc.decision_count + 1 }
            json
        else
          { acc with failure_count = acc.failure_count + 1 }
      | _ -> acc)
  in
  { stat with read_errors }

let scheduled_read_errors stat = stat.read_errors

let scheduled_evidence_json stat =
  `Assoc [
    ("decision_count", `Int stat.decision_count);
    ("failure_count", `Int stat.failure_count);
    ( "latest_ts_unix", Json_util.float_opt_to_json stat.latest_ts_unix );
    ( "latest_ts", Json_util.string_opt_to_json stat.latest_ts );
    ("read_error_count", `Int (List.length stat.read_errors));
    ("read_errors", `List stat.read_errors);
  ]

(* A turn-exchange row is any cycle whose channel parses to a known typed
   channel (Reactive / Scheduled_autonomous). Legacy spellings
   ("reactive"/"proactive") and the non-interaction "heartbeat" marker no
   longer count (RFC-0020 Phase 1 PR-3, owner decision 2026-06-15). *)
let is_turn_exchange_channel = function
  | Some s -> Option.is_some (Keeper_world_observation.channel_of_string s)
  | None -> false

let update_turn_span stat ts =
  {
    interaction_count = stat.interaction_count + 1;
    first_ts =
      Some
        (match stat.first_ts with
         | Some first -> min first ts
         | None -> ts);
    latest_ts =
      Some
        (match stat.latest_ts with
         | Some latest -> max latest ts
         | None -> ts);
  }

let turn_span_stats ~config keeper_name =
  let stat, read_errors =
    fold_keeper_decision_log_with_read_errors ~config keeper_name ~init:empty_turn_span_stat
    ~f:(fun stat json ->
      if is_turn_exchange_channel (Safe_ops.json_string_opt "channel" json) then
        match decision_ts_unix json with
        | Some ts -> update_turn_span stat ts
        | None -> stat
      else stat)
  in
  { stat with read_errors }

let turn_span_read_errors stat = stat.read_errors

let hours_between first latest =
  max 0.0 (latest -. first) /. seconds_per_hour

let latest_age_hours ~now latest =
  max 0.0 (now -. latest) /. seconds_per_hour

let unix_opt_to_json = function
  | Some ts when ts > 0.0 -> `Float ts
  | _ -> `Null

let unix_opt_to_iso_json = function
  | Some ts when ts > 0.0 ->
    `String (Masc_domain.iso8601_of_unix_seconds ts)
  | _ -> `Null

let turn_span_hours_json stat =
  match stat.first_ts, stat.latest_ts with
  | Some first, Some latest -> `Float (hours_between first latest)
  | _ -> `Null

let latest_age_hours_json ~now stat =
  match stat.latest_ts with
  | Some latest -> `Float (latest_age_hours ~now latest)
  | None -> `Null

let has_persistent_turn_span ~now stat =
  stat.interaction_count >= 2
  &&
  match stat.first_ts, stat.latest_ts with
  | Some first, Some latest ->
    hours_between first latest >= persistent_turn_window_hours
    && latest_age_hours ~now latest <= recent_turn_max_age_hours
  | _ -> false

let turn_span_evidence_json ~now keeper_name stat =
  `Assoc [
    ("keeper", `String keeper_name);
    ("interaction_count", `Int stat.interaction_count);
    ("first_ts_unix", unix_opt_to_json stat.first_ts);
    ("first_ts_iso", unix_opt_to_iso_json stat.first_ts);
    ("latest_ts_unix", unix_opt_to_json stat.latest_ts);
    ("latest_ts_iso", unix_opt_to_iso_json stat.latest_ts);
    ("span_hours", turn_span_hours_json stat);
    ("latest_age_hours", latest_age_hours_json ~now stat);
    ("read_error_count", `Int (List.length stat.read_errors));
    ("read_errors", `List stat.read_errors);
    ( "meets_24h_persistence",
      `Bool (has_persistent_turn_span ~now stat) );
  ]
