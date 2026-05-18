(** Runtime event-bus and memory summary JSON helpers.

    Split from {!Server_dashboard_http_keeper_api}; these helpers derive
    compact summary JSON from the runtime manifest scan. *)

let json_string_list values = `List (List.map (fun value -> `String value) values)

let event_bus_summary_json scan =
  let correlation_ids =
    scan.Server_dashboard_http_keeper_runtime_manifest_scan.event_bus_correlation_ids
    |> List.rev
    |> Json_util.dedupe_keep_order
  in
  let run_ids =
    scan.Server_dashboard_http_keeper_runtime_manifest_scan.event_bus_run_ids
    |> List.rev
    |> Json_util.dedupe_keep_order
  in
  let last_compaction =
    match scan.Server_dashboard_http_keeper_runtime_manifest_scan.last_compaction with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [
      ( "event_bus_correlated_count",
        `Int scan.Server_dashboard_http_keeper_runtime_manifest_scan.event_bus_count );
      ("correlation_ids", json_string_list correlation_ids);
      ("run_ids", json_string_list run_ids);
      ( "context_compact_started_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .context_compact_started_count );
      ( "context_compacted_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .context_compacted_count );
      ("last_compaction", last_compaction);
    ]

let memory_summary_json scan =
  `Assoc
    [
      ( "memory_injected_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .memory_injected_count );
      ( "memory_injected_present_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .memory_injected_present_count );
      ( "memory_flushed_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .memory_flushed_count );
      ( "memory_flush_success_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .memory_flush_success_count );
      ( "memory_flush_error_count",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .memory_flush_error_count );
      ( "episodes_flushed",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .episodes_flushed );
      ( "procedures_flushed",
        `Int
          scan
            .Server_dashboard_http_keeper_runtime_manifest_scan
             .procedures_flushed );
    ]
