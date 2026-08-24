type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}


let recent_turn_max_age_hours = 24.0

let decision_tail_max_bytes = 512 * 1024
let decision_tail_max_lines = 5000


let empty_scheduled_stat =
  { decision_count = 0; latest_ts = None; latest_ts_unix = None; failure_count = 0 }

let fold_keeper_decision_log ~config keeper_name ~init ~f =
  let path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then init
  else
    (match
       Keeper_memory.read_file_tail_lines_result path
         ~max_bytes:decision_tail_max_bytes
         ~max_lines:decision_tail_max_lines
     with
     | Ok lines -> lines
     | Error exn_class ->
         Keeper_memory.record_memory_recall_read_error
           ~site:"dashboard_decision_log_proof" path exn_class;
         [])
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
    ( "latest_ts_unix", Json_util.float_opt_to_json stat.latest_ts_unix );
    ( "latest_ts", Json_util.string_opt_to_json stat.latest_ts );
  ]
