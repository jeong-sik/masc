open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let json_int_opt = Scan_summary.json_int_opt
let json_string_list = Scan_summary.json_string_list
let memory_summary_json = Scan_summary.memory_summary_json
let selected_keeper_turn_id = Scan_summary.selected_keeper_turn_id
let terminal_event_present_for_turn = Scan_summary.terminal_event_present_for_turn

let runtime_lens_json ~config ~keeper_name ~trace_id ?turn_id scan =
  let ( tool_decision
      , lane_decision
      , requested_tools
      , required_tools
      , materialized_tools
      , missing_required_tools )
    =
    Server_dashboard_http_keeper_runtime_lens_gaps.runtime_lens_tool_surface_parts
      scan
  in
  let keeper_turn_id = selected_keeper_turn_id ?turn_id scan in
  let terminal_event_present =
    terminal_event_present_for_turn ?keeper_turn_id scan
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
  let runtime_proof =
    Server_dashboard_http_keeper_runtime_lens_proof.runtime_lens_runtime_proof_json
      ~keeper_name
      ~trace_id
      ?turn_id
      ()
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
  let tool_runtime_status =
    if missing_required_tools <> [] then "missing_required_tool"
    else if
      runtime_lens_event_count scan
        Keeper_runtime_manifest.Tool_surface_selected
      > 0
    then "selected"
    else "empty"
  in
  `Assoc
    [
      ( "turn_clock",
        `Assoc
          [
            ("trace_id", `String trace_id);
            ("keeper_turn_id", json_int_opt keeper_turn_id);
            ("max_oas_turn_count", json_int_opt scan.max_oas_turn_count);
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
            ( "tool_surface",
              `Assoc
                [
                  ("requested_tools", json_string_list requested_tools);
                  ("required_tools", json_string_list required_tools);
                  ("materialized_tools", json_string_list materialized_tools);
                  ( "missing_required_tools",
                    json_string_list missing_required_tools );
                  ( "turn_lane",
                    json_string_opt
                      (json_string_member_opt "turn_lane" tool_decision) );
                  ( "tool_surface_class",
                    json_string_opt
                      (json_string_member_opt "tool_surface_class"
                         tool_decision) );
                  ( "tool_requirement",
                    json_string_opt
                      (first_string_opt
                         [
                           json_string_member_opt "tool_requirement"
                             tool_decision;
                           json_string_member_opt "tool_requirement"
                             lane_decision;
                         ]) );
                  ( "visible_tool_count",
                    json_int_opt
                      (first_int_opt
                         [
                           json_int_member_opt "visible_tool_count"
                             tool_decision;
                           json_int_member_opt "effective_tool_count"
                             lane_decision;
                         ]) );
                  ( "tool_gate_enabled",
                    match
                      json_bool_member_opt "tool_gate_enabled" tool_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ( "tool_surface_fallback_used",
                    match
                      json_bool_member_opt "tool_surface_fallback_used"
                        tool_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ("terminal_status", `String tool_runtime_status);
                ] );
            ( "provider_lane",
              `Assoc
                [
                  ("resolved", `Bool has_provider_lane);
                  ("status", json_string_opt provider_lane_status);
                  ( "resolved_lane",
                    json_string_opt
                      (json_string_member_opt "resolved_lane" lane_decision)
                  );
                  ( "effective_tool_count",
                    json_int_opt
                      (json_int_member_opt "effective_tool_count"
                         lane_decision) );
                  ( "runtime_mcp_policy_present",
                    match
                      json_bool_member_opt "runtime_mcp_policy_present"
                        lane_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ("required_tools", json_string_list required_tools);
                  ("materialized_tools", json_string_list materialized_tools);
                  ( "missing_required_tools",
                    json_string_list missing_required_tools );
                ] );
            ( "provider_attempt",
              `Assoc
                [
                  ("started_count", `Int scan.provider_started_count);
                  ("finished_count", `Int scan.provider_finished_count);
                  ( "terminal_status",
                    json_string_opt
                      (Option.map
                         (fun row -> row.Keeper_runtime_manifest.status)
                         scan.provider_terminal_row) );
                ] );
            ("claim_scope", claim_scope);
            ("config_drift", config_drift);
            ("runtime_proof", runtime_proof);
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
                  ( "state_snapshot_sidecar_saved_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.State_snapshot_sidecar_saved)
                  );
                  ( "last_compaction",
                    match scan.last_compaction with
                    | Some value -> value
                    | None -> `Null );
                ] );
            ("memory", memory_summary_json scan);
          ] );
      ( "swimlanes",
        `Assoc
          [
            ( "keeper",
              runtime_lens_swimlane_json scan gaps ~lane:"keeper"
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
            );
            ( "masc_policy_cascade",
              runtime_lens_swimlane_json scan gaps
                ~lane:"masc_policy_cascade" ~label:"MASC Cascade"
                ~events:
                  [
                    Keeper_runtime_manifest.Cascade_routed;
                    Keeper_runtime_manifest.Provider_lane_resolved;
                  ]
                ~terminal_status:
                  (Option.value provider_lane_status
                     ~default:
                       (if has_provider_lane then "resolved" else "empty"))
            );
            ( "oas_agent",
              runtime_lens_swimlane_json scan gaps ~lane:"oas_agent"
                ~label:"OAS"
                ~events:
                  [
                    Keeper_runtime_manifest.Checkpoint_loaded;
                    Keeper_runtime_manifest.State_snapshot_sidecar_saved;
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
                   else "empty") );
            ( "provider",
              runtime_lens_swimlane_json scan gaps ~lane:"provider"
                ~label:"Provider"
                ~events:
                  [
                    Keeper_runtime_manifest.Provider_attempt_started;
                    Keeper_runtime_manifest.Provider_attempt_finished;
                  ]
                ~terminal_status:(runtime_lens_provider_terminal_status scan)
            );
            ( "tool_runtime",
              runtime_lens_swimlane_json scan gaps ~lane:"tool_runtime"
                ~label:"Tool Runtime"
                ~events:[ Keeper_runtime_manifest.Tool_surface_selected ]
                ~terminal_status:tool_runtime_status );
            ( "memory_context",
              runtime_lens_swimlane_json scan gaps ~lane:"memory_context"
                ~label:"Memory/Context"
                ~events:
                  [
                    Keeper_runtime_manifest.Context_injected;
                    Keeper_runtime_manifest.Context_compacted;
                    Keeper_runtime_manifest.Event_bus_correlated;
                    Keeper_runtime_manifest.Memory_injected;
                    Keeper_runtime_manifest.Memory_flushed;
                  ]
                ~terminal_status:(runtime_lens_memory_terminal_status scan) );
          ] );
      ("gaps", `List (List.map runtime_lens_gap_json gaps));
    ]
