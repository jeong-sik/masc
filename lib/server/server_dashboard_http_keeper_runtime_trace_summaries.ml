(** Provider-attempt and turn-identity summaries for runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; these summaries sit
    between raw manifest/receipt rows and the final runtime-trace response. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan

let unique_ints values =
  values |> List.sort_uniq Int.compare

let json_int_list values = `List (List.map (fun value -> `Int value) values)

let provider_attempts_summary_json scan =
  let attempt_rows = queue_to_list scan.provider_attempt_rows in
  let terminal = scan.provider_terminal_row in
  let terminal_decision_string key =
    Option.bind terminal (fun row ->
      json_string_member_opt key row.Keeper_runtime_manifest.decision)
  in
  `Assoc
    [
      ("started_count", `Int scan.provider_started_count);
      ("finished_count", `Int scan.provider_finished_count);
      ( "terminal_status",
        json_string_opt
          (Option.map (fun row -> row.Keeper_runtime_manifest.status) terminal) );
      ( "terminal_model_source",
        json_string_opt (terminal_decision_string "model_source") );
      ( "terminal_resolved_model_source",
        json_string_opt (terminal_decision_string "resolved_model_source") );
      ( "terminal_capability_source",
        json_string_opt (terminal_decision_string "capability_source") );
      ( "terminal_fallback_authority",
        json_string_opt (terminal_decision_string "fallback_authority") );
      ( "terminal_provider_source_cascade",
        json_string_opt (terminal_decision_string "provider_source_cascade") );
      ( "terminal_error",
        json_string_opt (terminal_decision_string "error") );
      ( "terminal_exception_kind",
        json_string_opt (terminal_decision_string "exception_kind") );
      ("attempts", `List (List.map provider_attempt_row_json attempt_rows));
    ]

let turn_identity_summary_json ?turn_id scan receipts =
  let manifest_keeper_turn_ids =
    scan.keeper_turn_ids
    |> List.rev
    |> unique_ints
  in
  let receipt_turn_counts =
    receipts
    |> List.filter_map (json_int_member_opt "turn_count")
    |> unique_ints
  in
  `Assoc
    [
      ( "requested_keeper_turn_id",
        match turn_id with Some value -> `Int value | None -> `Null );
      ("manifest_keeper_turn_ids", json_int_list manifest_keeper_turn_ids);
      ("receipt_turn_counts", json_int_list receipt_turn_counts);
      ("max_oas_turn_count", json_int_opt scan.max_oas_turn_count);
      ( "provider_lane_resolved_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_lane_resolved) );
      ( "provider_attempt_started_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_attempt_started) );
      ( "provider_attempt_finished_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_attempt_finished) );
      ( "checkpoint_saved_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Checkpoint_saved) );
      ( "event_bus_correlated_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Event_bus_correlated) );
      ( "memory_injected_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Memory_injected) );
      ( "memory_flushed_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Memory_flushed) );
      ( "receipt_appended_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Receipt_appended) );
      ( "turn_finished_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Turn_finished) );
    ]
