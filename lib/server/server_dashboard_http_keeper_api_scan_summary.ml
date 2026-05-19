(** Runtime-manifest scan: receipt-matching + summary-JSON helpers.

    Extracted from [server_dashboard_http_keeper_api.ml] (lines
    141-235) as part of the godfile decomp campaign. Pure helper
    functions over the
    [Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan] record and
    JSONL receipt rows on disk.

    Surface ownership:
    - receipt row matching ({!receipt_row_matches}, {!read_receipt_rows})
      — operate on raw [Yojson.Safe.t] rows + paths;
    - generic JSON helpers ({!unique_ints}, {!json_int_list},
      {!json_int_opt}, {!json_string_list}) — local single-use sugar;
    - per-section scan summaries ({!event_bus_summary_json},
      {!memory_summary_json}) — fold the manifest scan record into a
      single [`Assoc] for dashboard payload;
    - turn-id selection helpers ({!max_int_list_opt},
      {!selected_keeper_turn_id}, {!terminal_event_present_for_turn})
      — used to pick the active keeper turn for runtime-lens. *)

open Server_dashboard_http_keeper_api_types

let receipt_row_matches ?turn_id keeper_name trace_id json =
  let keeper_matches = json_string_member_opt "keeper_name" json = Some keeper_name in
  let trace_matches = json_string_member_opt "trace_id" json = Some trace_id in
  let turn_matches =
    match turn_id with
    | None -> false
    | Some wanted -> json_int_member_opt "turn_count" json = Some wanted
  in
  keeper_matches && (trace_matches || turn_matches)
;;

let read_receipt_rows ~keeper_name ~trace_id ?turn_id paths =
  paths
  |> List.concat_map (fun path ->
    Fs_compat.fold_jsonl_lines
      ~init:[]
      ~f:(fun acc ~line_no:_ json ->
        if receipt_row_matches ?turn_id keeper_name trace_id json then json :: acc else acc)
      path
    |> List.rev)
;;

let unique_ints values = values |> List.sort_uniq Int.compare
let json_int_list values = `List (List.map (fun value -> `Int value) values)

let json_int_opt = function
  | None -> `Null
  | Some value -> `Int value
;;

let json_string_list values = `List (List.map (fun value -> `String value) values)

let event_bus_summary_json
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  let correlation_ids =
    scan.event_bus_correlation_ids |> List.rev |> Json_util.dedupe_keep_order
  in
  let run_ids = scan.event_bus_run_ids |> List.rev |> Json_util.dedupe_keep_order in
  let last_compaction =
    match scan.last_compaction with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [ "event_bus_correlated_count", `Int scan.event_bus_count
    ; "correlation_ids", json_string_list correlation_ids
    ; "run_ids", json_string_list run_ids
    ; "context_compact_started_count", `Int scan.context_compact_started_count
    ; "context_compacted_count", `Int scan.context_compacted_count
    ; "last_compaction", last_compaction
    ]
;;

let memory_summary_json
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  `Assoc
    [ "memory_injected_count", `Int scan.memory_injected_count
    ; "memory_injected_present_count", `Int scan.memory_injected_present_count
    ; "memory_flushed_count", `Int scan.memory_flushed_count
    ; "memory_flush_success_count", `Int scan.memory_flush_success_count
    ; "memory_flush_error_count", `Int scan.memory_flush_error_count
    ; "episodes_flushed", `Int scan.episodes_flushed
    ; "procedures_flushed", `Int scan.procedures_flushed
    ]
;;

let max_int_list_opt values =
  List.fold_left
    (fun acc value ->
       match acc with
       | None -> Some value
       | Some existing -> Some (max existing value))
    None
    values
;;

let selected_keeper_turn_id
      ?turn_id
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  match turn_id with
  | Some value -> Some value
  | None -> max_int_list_opt scan.keeper_turn_ids
;;

let terminal_event_present_for_turn
      ?keeper_turn_id
      (scan : Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan)
  =
  match keeper_turn_id with
  | Some value -> List.mem value scan.terminal_keeper_turn_ids
  | None -> scan.has_terminal
;;
