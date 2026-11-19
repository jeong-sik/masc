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

type tool_audit_read_state =
  | Tool_audit_read
  | Tool_audit_timed_out
  | Tool_audit_unreadable

let tool_audit_read_field = "tool_audit_read"
let tool_audit_read_error_field = "tool_audit_read_error"

let tool_audit_read_state_to_wire = function
  | Tool_audit_read -> "read"
  | Tool_audit_timed_out -> "timed_out"
  | Tool_audit_unreadable -> "unreadable"

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

(* The tool audit of a metrics row: a turn row with its tools, their count
   and its time has one. A heartbeat row has none, nor has a row of a kind
   this build does not read. A row that cannot be read at all is reported
   against the Keeper's metrics directory and has none either. *)
let tool_audit_of_metrics_row ~base_dir entry =
  let report_drop ~reason ~detail =
    report_persistence_read_drop
      ~surface:metrics_tool_audit_persistence_surface
      ~reason
      ~path:base_dir
      ~detail
  in
  match entry with
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
              Json_util.json_string_list_member_strict "tools_used" json,
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

(* The tool audit of the newest turn row of a Keeper's metrics store. The
   store keeps it in memory in the process that writes the store
   ([Dated_jsonl.Store.facts]): the turn row a Keeper's turn appends replaces
   it, and a heartbeat row leaves it as it is. *)
let newest_turn_tool_audit : tool_audit_snapshot option Dated_jsonl.fact =
  Dated_jsonl.newest_selected
    ~name:"keeper_turn_tool_audit"
    ~select:tool_audit_of_metrics_row

let latest_tool_audit_snapshot_from_files config ~keeper_name =
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  match Dated_jsonl.read_fact store newest_turn_tool_audit with
  | Fact_cell.Held snapshot
  | Fact_cell.Read_and_kept snapshot
  | Fact_cell.Read_not_kept snapshot -> Ok snapshot
  | Fact_cell.Read_failed error ->
    report_persistence_read_drop
      ~surface:metrics_tool_audit_persistence_surface
      ~reason:Read_drop_reason.Entry_load_error
      ~path:(Dated_jsonl.base_dir store)
      ~detail:(Dated_jsonl.read_error_to_string error);
    Error error
