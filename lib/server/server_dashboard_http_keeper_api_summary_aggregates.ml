(* Aggregate summary JSON builders consumed by
   [Server_dashboard_http_keeper_api.keeper_runtime_trace_json]:
     - provider attempts terminal/list aggregation
     - turn-identity counts derived from manifest scan + receipt rows

   Pulled out of [server_dashboard_http_keeper_api.ml] to shrink the
   godfile.  All inputs are typed values from sibling modules so there
   is no shared state. *)

open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_api_types

module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let provider_attempts_summary_json (scan : runtime_manifest_scan) : Yojson.Safe.t =
  let attempt_rows = queue_to_list scan.provider_attempt_rows in
  let terminal = scan.provider_terminal_row in
  let terminal_decision_string key =
    Option.bind terminal (fun row ->
      json_string_member_opt key row.Keeper_runtime_manifest.decision)
  in
  `Assoc
    [ "started_count", `Int scan.provider_started_count
    ; "finished_count", `Int scan.provider_finished_count
    ; ( "terminal_status"
      , json_string_opt
          (Option.map (fun row -> row.Keeper_runtime_manifest.status) terminal) )
    ; "terminal_model_source", json_string_opt (terminal_decision_string "model_source")
    ; ( "terminal_resolved_model_source"
      , json_string_opt (terminal_decision_string "resolved_model_source") )
    ; ( "terminal_capability_source"
      , json_string_opt (terminal_decision_string "capability_source") )
    ; ( "terminal_fallback_authority"
      , json_string_opt (terminal_decision_string "fallback_authority") )
    ; ( "terminal_provider_source_cascade"
      , json_string_opt (terminal_decision_string "provider_source_cascade") )
    ; "terminal_error", json_string_opt (terminal_decision_string "error")
    ; ( "terminal_exception_kind"
      , json_string_opt (terminal_decision_string "exception_kind") )
    ; "attempts", `List (List.map provider_attempt_row_json attempt_rows)
    ]
;;

let turn_identity_summary_json
      ?turn_id
      (scan : runtime_manifest_scan)
      (receipts : Yojson.Safe.t list)
  : Yojson.Safe.t
  =
  let manifest_keeper_turn_ids =
    scan.keeper_turn_ids |> List.rev |> Scan_summary.unique_ints
  in
  let receipt_turn_counts =
    receipts
    |> List.filter_map (json_int_member_opt "turn_count")
    |> Scan_summary.unique_ints
  in
  `Assoc
    [ ( "requested_keeper_turn_id"
      , match turn_id with
        | Some value -> `Int value
        | None -> `Null )
    ; "manifest_keeper_turn_ids", Scan_summary.json_int_list manifest_keeper_turn_ids
    ; "receipt_turn_counts", Scan_summary.json_int_list receipt_turn_counts
    ; "max_oas_turn_count", Scan_summary.json_int_opt scan.max_oas_turn_count
    ; ( "provider_lane_resolved_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Provider_lane_resolved) )
    ; ( "provider_attempt_started_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Provider_attempt_started) )
    ; ( "provider_attempt_finished_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Provider_attempt_finished) )
    ; ( "checkpoint_saved_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Checkpoint_saved) )
    ; ( "event_bus_correlated_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Event_bus_correlated) )
    ; ( "memory_injected_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Memory_injected) )
    ; ( "memory_flushed_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Memory_flushed) )
    ; ( "receipt_appended_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Receipt_appended) )
    ; ( "turn_finished_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Turn_finished) )
    ]
;;
