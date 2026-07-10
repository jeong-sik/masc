open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let selected_keeper_turn_id = Scan_summary.selected_keeper_turn_id
let terminal_event_present_for_turn = Scan_summary.terminal_event_present_for_turn

let runtime_lens_json ~config ~keeper_name ~trace_id ?turn_id scan =
  let lane_decision =
    match scan.latest_provider_lane_decision with
    | Some decision -> decision
    | None -> `Assoc []
  in
  let keeper_turn_id = selected_keeper_turn_id ?turn_id scan in
  let terminal_event_present =
    terminal_event_present_for_turn ?keeper_turn_id scan
  in
  let swimlane_scan =
    match (turn_id, keeper_turn_id) with
    | Some _, _ | _, None -> scan
    | None, Some selected_turn_id ->
      read_runtime_manifest_scan ~config ~keeper_name ~trace_id
        ~turn_id:selected_turn_id ~limit:scan.limit ()
  in
  let claim_scope =
    Server_dashboard_http_keeper_runtime_lens_summaries.claim_scope_summary_json
      ~keeper_name
      ~trace_id
      ?turn_id
      ()
  in
  let config_drift =
    Server_dashboard_http_keeper_runtime_lens_summaries.config_drift_summary_json
      ~config
      ~keeper_name
  in
  let gaps =
    Server_dashboard_http_keeper_runtime_lens_gaps.runtime_lens_gaps
      ~terminal_event_present
      ~claim_scope
      ~config_drift
      scan
  in
  let has_provider_lane =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Provider_lane_resolved
    > 0
  in
  let provider_lane_status =
    Option.map
      (fun row -> row.Keeper_runtime_manifest.status)
      scan.latest_provider_lane_row
  in
  `Assoc
    [
      ( "turn_clock",
        `Assoc
          [
            ("trace_id", `String trace_id);
            ("keeper_turn_id", Json_util.int_opt_to_json keeper_turn_id);
            ("max_oas_turn_count", Json_util.int_opt_to_json scan.max_oas_turn_count);
            ("terminal_event_present", `Bool terminal_event_present);
            ( "terminal_event",
              if terminal_event_present then `String "turn_finished" else `Null );
            ("manifest_total_rows", `Int scan.total_rows);
          ] );
      ( "axes",
        `Assoc
          [
            ( "lifecycle",
              `Assoc
                [
                  ( "turn_started_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Turn_started) );
                  ( "phase_gate_decided_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Phase_gate_decided) );
                  ( "pre_dispatch_blocked_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Pre_dispatch_blocked) );
                  ( "receipt_appended_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Receipt_appended) );
                  ( "turn_finished_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Turn_finished) );
                  ( "terminal_status",
                    `String
                      (runtime_lens_keeper_terminal_status
                         ~terminal_event_present
                         scan) );
                ] );
            ( "provider_lane",
              `Assoc
                [
                  ("resolved", `Bool has_provider_lane);
                  ("status", Json_util.string_opt_to_json provider_lane_status);
                  ( "resolved_lane",
                    Json_util.string_opt_to_json
                      (Json_util.get_string lane_decision "resolved_lane")
                  );
                ] );
            ( "payload_role",
              `Assoc
                (Hashtbl.fold
                   (fun role count acc -> (role, `Int count) :: acc)
                   scan.payload_role_counts []) );
            ( "source_clock",
              `Assoc
                (Hashtbl.fold
                   (fun clock count acc -> (clock, `Int count) :: acc)
                   scan.source_clock_counts []) );
            ( "provider_attempt",
              `Assoc
                [
                  ("started_count", `Int scan.provider_started_count);
                  ("finished_count", `Int scan.provider_finished_count);
                  ( "terminal_status",
                    Json_util.string_opt_to_json
                      (Option.map
                         (fun row -> row.Keeper_runtime_manifest.status)
                         scan.provider_terminal_row) );
                ] );
            ("claim_scope", claim_scope);
            ("config_drift", config_drift);
            ( "context",
              `Assoc
                [
                  ("context_injected_count", `Int scan.context_injected_count);
                  ( "context_compacted_event_count",
                    `Int scan.context_compacted_event_count );
                  ( "event_bus_correlated_count",
                    `Int scan.event_bus_count );
                  ( "context_compact_started_count",
                    `Int scan.context_compact_started_count );
                  ( "context_compacted_count",
                    `Int scan.context_compacted_count );
                  ( "checkpoint_loaded_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Checkpoint_loaded) );
                  ( "checkpoint_saved_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Checkpoint_saved) );
                  ( "last_compaction",
                    match scan.last_compaction with
                    | Some value -> value
                    | None -> `Null );
                ] );
          ] );
      ( "swimlanes",
        `Assoc
          [
            ( "keeper",
              runtime_lens_swimlane_json swimlane_scan gaps ~lane:"keeper"
                ~label:"Keeper"
                ~events:
                  [
                    Keeper_runtime_manifest.Turn_started;
                    Keeper_runtime_manifest.Phase_gate_decided;
                    Keeper_runtime_manifest.Pre_dispatch_blocked;
                    Keeper_runtime_manifest.Receipt_appended;
                    Keeper_runtime_manifest.Turn_finished;
                  ]
                ~terminal_status:
                  (runtime_lens_keeper_terminal_status ~terminal_event_present scan)
                ~synthetic_events:[]
            );
            ( "masc_policy_runtime",
              runtime_lens_swimlane_json swimlane_scan gaps
                ~lane:"masc_policy_runtime" ~label:"MASC Runtime"
                ~events:
                  [
                    Keeper_runtime_manifest.Runtime_routed;
                    Keeper_runtime_manifest.Provider_lane_resolved;
                  ]
                ~terminal_status:
                  (Option.value provider_lane_status
                     ~default:
                       (if has_provider_lane then "resolved" else "empty"))
                ~synthetic_events:[]
            );
            ( "oas_agent",
              runtime_lens_swimlane_json swimlane_scan gaps ~lane:"oas_agent"
                ~label:"OAS"
                ~events:
                  [
                    Keeper_runtime_manifest.Checkpoint_loaded;
                    Keeper_runtime_manifest.Checkpoint_saved;
                  ]
                ~terminal_status:
                  (if
                     runtime_lens_event_count scan
                       Keeper_runtime_manifest.Checkpoint_saved
                     > 0
                   then "checkpoint_saved"
                   else if
                     runtime_lens_event_count scan
                       Keeper_runtime_manifest.Checkpoint_loaded
                     > 0
                   then "checkpoint_loaded"
                   else "empty")
                ~synthetic_events:[] );
            ( "provider",
              runtime_lens_swimlane_json swimlane_scan gaps ~lane:"provider"
                ~label:"Provider"
                ~events:
                  [
                    Keeper_runtime_manifest.Provider_attempt_started;
                    Keeper_runtime_manifest.Provider_attempt_finished;
                  ]
                ~terminal_status:(runtime_lens_provider_terminal_status scan)
                ~synthetic_events:[]
            );
            ( "tool_runtime",
              runtime_lens_swimlane_json swimlane_scan gaps ~lane:"tool_runtime"
                ~label:"Tool Runtime"
                ~events:[]
                ~synthetic_events:[]
                ~terminal_status:"not_observed" );
            ( "memory_context",
              runtime_lens_swimlane_json swimlane_scan gaps ~lane:"memory_context"
                ~label:"Memory/Context/Checkpoint"
                ~events:
                  [
                    Keeper_runtime_manifest.Context_injected;
                    Keeper_runtime_manifest.Context_compacted;
                    Keeper_runtime_manifest.Event_bus_correlated;
                    Keeper_runtime_manifest.Checkpoint_loaded;
                    Keeper_runtime_manifest.Checkpoint_saved;
                  ]
                ~terminal_status:(runtime_lens_memory_terminal_status scan)
                ~synthetic_events:[] );
          ] );
      ( "clock_edges",
        Server_dashboard_http_keeper_runtime_lens_clock_edges.runtime_lens_clock_edges_json
          scan );
      ( "clock_groups",
        Server_dashboard_http_keeper_runtime_lens_clock_groups.runtime_lens_clock_groups_json
          scan );
      ("gaps", `List (List.map runtime_lens_gap_json gaps));
    ]
