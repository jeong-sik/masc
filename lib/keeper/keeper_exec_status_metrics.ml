(** Keeper_exec_status_metrics — metrics summary type, serialization, and
    line-based aggregation. Split from keeper_exec_status.ml. *)


(** Metrics summary types, serialization, and aggregation extracted to
    [Keeper_exec_status_metrics_types].  Audit snapshot functions below. *)

include Keeper_exec_status_metrics_types

let json_string_list_member key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
  | _ -> []

let json_int_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Int value -> Some value
  | `Intlit raw -> (int_of_string_opt (raw))
  | `Float value -> Some (int_of_float value)
  | _ -> None

let action_source_opt_member json =
  match Safe_ops.json_string_opt "action_source" json with
  | Some _ as value -> value
  | None -> (
      match Yojson.Safe.Util.member "deliberation_execution" json with
      | `Assoc _ as nested ->
          Safe_ops.json_string_opt "action_source" nested
      | _ -> None)

let has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source =
  tools <> []
  || Option.fold ~none:false ~some:(fun count -> count > 0) raw_tool_call_count
  || Option.is_some action_source

let json_iso_opt json =
  match Safe_ops.json_string_opt "ts" json with
  | Some text ->
      let trimmed = String.trim text in
      if trimmed <> "" then Some trimmed
      else
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" json in
        if ts_unix > 0.0 then Some (Dashboard_utils.iso_of_unix ts_unix) else None
  | None ->
      let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" json in
      if ts_unix > 0.0 then Some (Dashboard_utils.iso_of_unix ts_unix) else None

let read_recent_metrics_lines config keeper_name =
  let store = Keeper_types.keeper_metrics_store config keeper_name in
  let dated = Dated_jsonl.read_recent_lines store 8 in
  if dated <> [] then dated
  else
    let metrics_path = Keeper_types.keeper_metrics_path config keeper_name in
    Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:40000 ~max_lines:8

let latest_snapshot_of_lines lines ~parse_snapshot ~has_legacy_shape =
  let ordered = List.rev lines in
  match List.find_map parse_snapshot ordered with
  | Some _ as snapshot -> snapshot
  | None ->
      List.find_map
        (fun line ->
          try
            let json = Yojson.Safe.from_string line in
            let snapshot =
              match json with
              | `Assoc _ -> parse_snapshot line
              | _ -> None
            in
            match snapshot with
            | Some _ as snapshot -> snapshot
            | None ->
                if has_legacy_shape json then
                  Some
                    {
                      latest_tool_names = [];
                      latest_tool_call_count = Some 0;
                      latest_action_source = None;
                      tool_audit_source = None;
                      tool_audit_at = json_iso_opt json;
                    }
                else None
          with Yojson.Json_error _ -> None)
        ordered

let latest_tool_audit_snapshot_from_decisions config keeper_name =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    let lines = Keeper_memory.read_file_tail_lines path ~max_bytes:40000 ~max_lines:12 in
    let report_drop ~reason ~detail =
      report_persistence_read_drop
        ~surface:decision_log_tool_audit_persistence_surface
        ~reason
        ~path
        ~detail
    in
    let parse_snapshot line =
      try
        let json =
          match Yojson.Safe.from_string line with
          | `Assoc _ as json -> json
          | _ ->
              report_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~detail:"decision log row is not a JSON object";
              raise Exit
        in
        let tools = json_string_list_member "tools_used" json in
        let raw_tool_call_count = json_int_opt_member "tool_call_count" json in
        let tool_call_count =
          match raw_tool_call_count with
          | Some _ as value -> value
          | None -> Some (List.length tools)
        in
        let action_source = action_source_opt_member json in
        if not (has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source)
        then None
        else
          Some
            {
              latest_tool_names = List.sort_uniq String.compare tools;
              latest_tool_call_count = tool_call_count;
              latest_action_source = action_source;
              tool_audit_source = Some "keeper_decision_log";
              tool_audit_at = json_iso_opt json;
            }
      with
      | Exit -> None
      | Yojson.Json_error detail ->
          report_drop
            ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
            ~detail;
          None
    in
    latest_snapshot_of_lines lines
      ~parse_snapshot
      ~has_legacy_shape:(fun json ->
        Option.is_some (json_iso_opt json)
        || Option.is_some (Safe_ops.json_string_opt "turn_mode" json)
        || Option.is_some (Safe_ops.json_string_opt "selected_mode" json)
        || Option.is_some (Safe_ops.json_string_opt "outcome" json))
    |> Option.map (fun snapshot ->
           {
             snapshot with
             tool_audit_source =
               Some
                 (Option.value ~default:"keeper_decision_log"
                    snapshot.tool_audit_source);
           })

let latest_tool_audit_snapshot_from_metrics config keeper_name =
  let lines = read_recent_metrics_lines config keeper_name in
  let metrics_path = Keeper_types.keeper_metrics_path config keeper_name in
  let report_drop ~reason ~detail =
    report_persistence_read_drop
      ~surface:metrics_tool_audit_persistence_surface
      ~reason
      ~path:metrics_path
      ~detail
  in
  let parse_snapshot line =
    try
      let json =
        match Yojson.Safe.from_string line with
        | `Assoc _ as json -> json
        | _ ->
            report_drop
              ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
              ~detail:"keeper metrics row is not a JSON object";
            raise Exit
      in
      let tools =
        json_string_list_member "tools_used" json
        |> List.sort_uniq String.compare
      in
      let raw_tool_call_count = json_int_opt_member "tool_call_count" json in
      let tool_call_count =
        match raw_tool_call_count with
        | Some _ as value -> value
        | None -> Some (List.length tools)
      in
      let action_source = action_source_opt_member json in
      if not (has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source)
      then None
      else
        Some
          {
            latest_tool_names = tools;
            latest_tool_call_count = tool_call_count;
            latest_action_source = action_source;
            tool_audit_source = Some "keeper_metrics";
            tool_audit_at = json_iso_opt json;
          }
    with
    | Exit -> None
    | Yojson.Json_error detail ->
        report_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~detail;
        None
  in
  latest_snapshot_of_lines lines
    ~parse_snapshot
    ~has_legacy_shape:(fun json ->
      Option.is_some (json_iso_opt json)
      || Option.is_some (Safe_ops.json_string_opt "channel" json)
      || Option.is_some (Safe_ops.json_string_opt "turn_mode" json)
      || Option.is_some (Safe_ops.json_string_opt "work_kind" json))
  |> Option.map (fun snapshot ->
         {
           snapshot with
           tool_audit_source =
             Some
               (Option.value ~default:"keeper_metrics"
                  snapshot.tool_audit_source);
         })

let latest_tool_audit_snapshot_from_files config ~keeper_name =
  match latest_tool_audit_snapshot_from_decisions config keeper_name with
  | Some _ as snapshot -> snapshot
  | None -> latest_tool_audit_snapshot_from_metrics config keeper_name

let accountability_summary_lookup config =
  Keeper_accountability.accountability_summary_lookup config

let accountability_summary_json config ~keeper_name ~agent_name =
  Keeper_accountability.accountability_summary_json config ~keeper_name
    ~agent_name
