type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}

type turn_span_stat = {
  interaction_count : int;
  first_ts : float option;
  latest_ts : float option;
}

let seconds_per_hour = 3600.0
let persistent_turn_window_hours = 24.0
let recent_turn_max_age_hours = 24.0
let decision_tail_max_bytes = 512 * 1024
let decision_tail_max_lines = 5000

let empty_scheduled_stat =
  { decision_count = 0; latest_ts = None; latest_ts_unix = None; failure_count = 0 }

let empty_turn_span_stat =
  { interaction_count = 0; first_ts = None; latest_ts = None }

let fold_keeper_decision_log ~config keeper_name ~init ~f =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then init
  else
    Keeper_memory.read_file_tail_lines path
      ~max_bytes:decision_tail_max_bytes
      ~max_lines:decision_tail_max_lines
    |> List.fold_left
         (fun acc line ->
            let line = String.trim line in
            if line = "" then acc
            else
              match Yojson.Safe.from_string line with
              | exception Yojson.Json_error _ -> acc
              | json -> f acc json)
         init

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
  fold_keeper_decision_log ~config keeper_name
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

let scheduled_evidence_json stat =
  `Assoc [
    ("decision_count", `Int stat.decision_count);
    ("failure_count", `Int stat.failure_count);
    ( "latest_ts_unix",
      match stat.latest_ts_unix with
      | Some ts -> `Float ts
      | None -> `Null );
    ( "latest_ts",
      match stat.latest_ts with
      | Some ts -> `String ts
      | None -> `Null );
  ]

let is_turn_exchange_channel = function
  | Some "reactive" | Some "scheduled_autonomous" | Some "turn"
  | Some "proactive" ->
    true
  | _ -> false

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
  fold_keeper_decision_log ~config keeper_name ~init:empty_turn_span_stat
    ~f:(fun stat json ->
      if is_turn_exchange_channel (Safe_ops.json_string_opt "channel" json) then
        match decision_ts_unix json with
        | Some ts -> update_turn_span stat ts
        | None -> stat
      else stat)

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
    ( "meets_24h_persistence",
      `Bool (has_persistent_turn_span ~now stat) );
  ]
