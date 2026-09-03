(* Aggregate summary JSON builders consumed by
   [Server_dashboard_http_keeper_api.keeper_runtime_trace_json]:
     - turn-identity counts derived from manifest scan + receipt rows

   Pulled out of [server_dashboard_http_keeper_api.ml] to shrink the
   godfile.  All inputs are typed values from sibling modules so there
   is no shared state. *)

open Server_dashboard_http_keeper_runtime_manifest_scan

module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

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
    |> List.filter_map (fun json -> Json_util.get_int json "turn_count")
    |> Scan_summary.unique_ints
  in
  `Assoc
    [ ( "requested_keeper_turn_id", Json_util.int_opt_to_json turn_id )
    ; "manifest_keeper_turn_ids", Scan_summary.json_int_list manifest_keeper_turn_ids
    ; "receipt_turn_counts", Scan_summary.json_int_list receipt_turn_counts
    ; "max_agent_core_turn_count", Json_util.int_opt_to_json scan.max_agent_core_turn_count
    ; ( "provider_lane_resolved_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Provider_lane_resolved) )
    ; ( "runtime_completed_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Runtime_completed) )
    ; ( "runtime_failed_count"
      , `Int
          (runtime_manifest_scan_event_count
             scan
             Keeper_runtime_manifest.Runtime_failed) )
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
