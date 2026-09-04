(** Keeper status projections over the current metrics-ledger contract. *)

type metrics_summary =
  { sample_points : int
  ; turn_points : int
  ; heartbeat_points : int
  ; proactive_points : int
  }

type tool_audit_snapshot =
  { latest_tool_names : string list
  ; latest_tool_call_count : int option
  ; latest_action_source : string option
  ; tool_audit_source : string option
  ; tool_audit_at : string option
  }

let metrics_summary_persistence_surface = "keeper_status_metrics"
let metrics_tool_audit_persistence_surface =
  "keeper_status_runtime_keeper_metrics"

let report_persistence_read_drop ~surface ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", surface; "reason", reason_wire ]
        ())
    ~surface
    ~reason
    ~path
    ~detail

let report_metrics_summary_read_drop ~reason ~detail =
  report_persistence_read_drop
    ~surface:metrics_summary_persistence_surface
    ~reason
    ~path:"<keeper_metrics_lines>"
    ~detail

let empty_metrics_summary =
  { sample_points = 0
  ; turn_points = 0
  ; heartbeat_points = 0
  ; proactive_points = 0
  }

let empty_tool_audit_snapshot =
  { latest_tool_names = []
  ; latest_tool_call_count = None
  ; latest_action_source = None
  ; tool_audit_source = None
  ; tool_audit_at = None
  }

let age_seconds_opt ~now_ts timestamp =
  if timestamp <= 0.0 then None else Some (now_ts -. timestamp)

let metrics_summary_to_json (summary : metrics_summary) : Yojson.Safe.t =
  let interaction_points =
    summary.turn_points + summary.proactive_points
  in
  `Assoc
    [ "sample_points", `Int summary.sample_points
    ; "turn_points", `Int summary.turn_points
    ; "heartbeat_points", `Int summary.heartbeat_points
    ; "proactive_points", `Int summary.proactive_points
    ; "window_interactions", `Int interaction_points
    ; ( "intervention_share"
      , Json_util.int_ratio_json summary.proactive_points interaction_points )
    ; ( "intervention_per_turn"
      , Json_util.int_ratio_json summary.proactive_points summary.turn_points )
    ]

let summarize_metrics_lines (lines : string list) : metrics_summary =
  List.fold_left
    (fun acc line ->
      try
        let json =
          match Yojson.Safe.from_string line with
          | `Assoc _ as json -> json
          | _ ->
              report_metrics_summary_read_drop
                ~reason:
                  Read_drop_reason.Invalid_payload
                ~detail:"keeper metrics row is not a JSON object";
              raise Exit
        in
        match Keeper_metrics_record.kind_of_json json with
        | None -> acc
        | Some Keeper_metrics_record.Heartbeat ->
            (match
               Safe_ops.json_float_opt "ts_unix" json,
               Safe_ops.json_string_opt "channel" json
             with
             | Some _, Some "heartbeat" ->
                 { acc with
                   sample_points = acc.sample_points + 1
                 ; heartbeat_points = acc.heartbeat_points + 1
                 }
             | _ -> acc)
        | Some Keeper_metrics_record.Turn ->
            let parsed_channel =
              Option.bind
                (Safe_ops.json_string_opt "channel" json)
                Keeper_world_observation.channel_of_string
            in
            (match
               Safe_ops.json_float_opt "ts_unix" json,
               Safe_ops.json_string_nonempty_opt "trace_id" json,
               parsed_channel
             with
             | Some _, Some _, Some channel ->
                 let is_turn =
                   match channel with
                   | Keeper_world_observation.Reactive -> true
                   | Keeper_world_observation.Scheduled_autonomous -> false
                 in
                 let is_scheduled_autonomous =
                   Keeper_world_observation.is_autonomous channel
                 in
                 { sample_points = acc.sample_points + 1
                 ; turn_points =
                     acc.turn_points + if is_turn then 1 else 0
                 ; heartbeat_points = acc.heartbeat_points
                 ; proactive_points =
                     acc.proactive_points
                     + if is_scheduled_autonomous then 1 else 0
                 }
             | _ -> acc)
      with
      | Exit -> acc
      | Yojson.Json_error detail ->
          report_metrics_summary_read_drop
            ~reason:
              Read_drop_reason.Json_syntax_error
            ~detail;
          acc
      | Yojson.Safe.Util.Type_error (detail, _) ->
          report_metrics_summary_read_drop
            ~reason:
              Read_drop_reason.Invalid_payload
            ~detail;
          acc)
    empty_metrics_summary
    lines

let string_list_member_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`List values) ->
      let rec decode acc = function
        | [] -> Some (List.rev acc)
        | `String value :: rest ->
            let value = String.trim value in
            if value = "" then None else decode (value :: acc) rest
        | _ -> None
      in
      decode [] values
  | _ -> None

module Tool_audit_cache = struct
  type entry =
    { physical_row_count : int
    ; snapshot : tool_audit_snapshot option
    }

  let entries : (string, entry) Hashtbl.t = Hashtbl.create 64
  let mutex = Stdlib.Mutex.create ()
  let max_entries = 256

  let find path =
    Stdlib.Mutex.protect mutex (fun () -> Hashtbl.find_opt entries path)

  let remove path =
    Stdlib.Mutex.protect mutex (fun () -> Hashtbl.remove entries path)

  let replace path entry =
    Stdlib.Mutex.protect mutex (fun () ->
      if
        (not (Hashtbl.mem entries path))
        && Hashtbl.length entries >= max_entries
      then Hashtbl.clear entries;
      Hashtbl.replace entries path entry)
end

let invalidate_tool_audit_cache config ~keeper_name =
  Keeper_types_support.keeper_metrics_dir config keeper_name
  |> Tool_audit_cache.remove

let latest_tool_audit_snapshot_from_metrics config keeper_name =
  let store =
    Keeper_types_support.keeper_metrics_store config keeper_name
  in
  let metrics_path =
    Keeper_types_support.keeper_metrics_dir config keeper_name
  in
  let report_drop ~reason ~detail =
    report_persistence_read_drop
      ~surface:metrics_tool_audit_persistence_surface
      ~reason
      ~path:metrics_path
      ~detail
  in
  let parse_snapshot = function
    | Dated_jsonl.Malformed_json { path; line_number; detail } ->
        let location =
          match line_number with
          | Some line_number -> Printf.sprintf "%s:%d" path line_number
          | None -> path
        in
        report_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~detail:(Printf.sprintf "%s: %s" location detail);
        None
    | Dated_jsonl.Parsed (`Assoc _ as json) ->
        (match Keeper_metrics_record.kind_of_json json with
         | Some Keeper_metrics_record.Turn ->
             (match
                string_list_member_opt "tools_used" json,
                Safe_ops.json_int_opt "tool_call_count" json,
                Safe_ops.json_string_nonempty_opt "ts" json
              with
              | Some tools, Some tool_call_count, Some timestamp ->
                  Some
                    { latest_tool_names = tools
                    ; latest_tool_call_count = Some tool_call_count
                    ; latest_action_source =
                        Safe_ops.json_string_nonempty_opt "action_source" json
                    ; tool_audit_source = Some "keeper_metrics"
                    ; tool_audit_at = Some timestamp
                    }
              | _ -> None)
         | Some Keeper_metrics_record.Heartbeat | None -> None)
    | Dated_jsonl.Parsed _ ->
        report_drop
          ~reason:Read_drop_reason.Invalid_payload
          ~detail:"keeper metrics row is not a JSON object";
        None
  in
  let report_read_error error =
    report_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~detail:(Dated_jsonl.read_error_to_string error)
  in
  let rows_stable ~physical_row_count =
    Dated_jsonl.count_entries store = physical_row_count
  in
  let cache_snapshot ~physical_row_count snapshot =
    Tool_audit_cache.replace
      metrics_path
      { physical_row_count; snapshot }
  in
  let scan_full physical_row_count =
    match Dated_jsonl.find_latest_entry_result store parse_snapshot with
    | Error error ->
        report_read_error error;
        None
    | Ok snapshot ->
        if rows_stable ~physical_row_count
        then cache_snapshot ~physical_row_count snapshot;
        snapshot
  in
  let physical_row_count = Dated_jsonl.count_entries store in
  match Tool_audit_cache.find metrics_path with
  | Some cached when cached.physical_row_count = physical_row_count ->
      cached.snapshot
  | Some cached when cached.physical_row_count < physical_row_count ->
      let appended_row_count =
        physical_row_count - cached.physical_row_count
      in
      (match Dated_jsonl.read_recent_result store appended_row_count with
       | Error error ->
           report_read_error error;
           None
       | Ok appended_entries ->
           let appended_snapshot =
             List.fold_left
               (fun latest entry ->
                 match parse_snapshot entry with
                 | Some snapshot -> Some snapshot
                 | None -> latest)
               None
               appended_entries
           in
           let snapshot =
             match appended_snapshot with
             | Some _ as snapshot -> snapshot
             | None -> cached.snapshot
           in
           if rows_stable ~physical_row_count
           then begin
             cache_snapshot ~physical_row_count snapshot;
             snapshot
           end
           else scan_full (Dated_jsonl.count_entries store))
  | Some _ | None -> scan_full physical_row_count

let latest_tool_audit_snapshot_from_files config ~keeper_name =
  latest_tool_audit_snapshot_from_metrics config keeper_name
