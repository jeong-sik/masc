(** Runtime-lens gap rendering and swimlane helpers.

    Split from {!Server_dashboard_http_keeper_api}; gap construction stays in
    the facade while repeated JSON rendering helpers live here. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan

type runtime_lens_gap =
  { code : string
  ; severity : string
  ; lane : string
  ; detail : string option
  }

let json_string_list values = `List (List.map (fun value -> `String value) values)

let runtime_lens_gap_json gap =
  `Assoc
    [
      ("code", `String gap.code);
      ("severity", `String gap.severity);
      ("lane", `String gap.lane);
      ("detail", json_string_opt gap.detail);
    ]

let runtime_lens_gap_codes_for_lane gaps lane =
  gaps
  |> List.filter_map (fun gap ->
       if String.equal gap.lane lane then Some gap.code else None)
  |> Json_util.dedupe_keep_order

let runtime_lens_event_count scan event =
  runtime_manifest_scan_event_count scan event

let runtime_lens_events_json scan events =
  events
  |> List.filter_map (fun event ->
       let count = runtime_lens_event_count scan event in
       if count = 0 then None
       else
         Some
           (`Assoc
             [
               ( "event",
                 `String (Keeper_runtime_manifest.event_kind_to_string event) );
               ("count", `Int count);
             ]))
  |> fun events -> `List events

let runtime_lens_swimlane_json scan gaps ~lane ~label ~events ~terminal_status =
  let gap_codes = runtime_lens_gap_codes_for_lane gaps lane in
  let event_count =
    events
    |> List.fold_left
         (fun total event -> total + runtime_lens_event_count scan event)
         0
  in
  `Assoc
    [
      ("lane", `String lane);
      ("label", `String label);
      ("event_count", `Int event_count);
      ("terminal_status", `String terminal_status);
      ("gap_codes", json_string_list gap_codes);
      ( "gap_badge",
        match gap_codes with
        | code :: _ -> `String code
        | [] -> `Null );
      ("events", runtime_lens_events_json scan events);
    ]

let runtime_lens_keeper_terminal_status ~terminal_event_present scan =
  if terminal_event_present then "finished"
  else if
    runtime_lens_event_count scan Keeper_runtime_manifest.Pre_dispatch_blocked
    > 0
  then "blocked"
  else if scan.total_rows = 0 then "empty"
  else "open"

let runtime_lens_provider_terminal_status scan =
  match scan.provider_terminal_row with
  | Some row -> row.Keeper_runtime_manifest.status
  | None when scan.provider_started_count > scan.provider_finished_count ->
    "unfinished"
  | None when scan.provider_started_count = 0 -> "not_started"
  | None -> "unknown"

let runtime_lens_memory_terminal_status scan =
  if scan.memory_flush_error_count > 0 then "memory_error"
  else if scan.memory_flush_success_count > 0 then "flushed"
  else if scan.memory_injected_count > 0 then "injected"
  else if
    scan.context_injected_count > 0
    || scan.context_compacted_event_count > 0
    || scan.event_bus_count > 0
  then "context"
  else "empty"

(** F8: lane mandatory event sets and terminal policy separation.

    [finished] = the lane's terminal event is present.
    [complete] = all mandatory events for the lane are present AND
                 the terminal event is present (or the lane has no terminal).

    This distinguishes "the turn ended" from "the lane fulfilled its contract". *)

type lane_policy =
  { lane : string
  ; mandatory_events : Keeper_runtime_manifest.event_kind list
  ; terminal_events : Keeper_runtime_manifest.event_kind list
  }

let lane_policies =
  [ { lane = "keeper"
    ; mandatory_events =
        [ Keeper_runtime_manifest.Turn_started
        ; Keeper_runtime_manifest.Turn_finished
        ]
    ; terminal_events = [ Keeper_runtime_manifest.Turn_finished ]
    }
  ; { lane = "provider"
    ; mandatory_events =
        [ Keeper_runtime_manifest.Provider_attempt_started
        ; Keeper_runtime_manifest.Provider_attempt_finished
        ]
    ; terminal_events = [ Keeper_runtime_manifest.Provider_attempt_finished ]
    }
  ; { lane = "tool_runtime"
    ; mandatory_events = [ Keeper_runtime_manifest.Tool_surface_selected ]
    ; terminal_events = []
    }
  ; { lane = "masc_policy_cascade"
    ; mandatory_events = [ Keeper_runtime_manifest.Cascade_routed ]
    ; terminal_events = []
    }
  ; { lane = "oas_agent"
    ; mandatory_events = [ Keeper_runtime_manifest.Checkpoint_saved ]
    ; terminal_events =
        [ Keeper_runtime_manifest.Checkpoint_saved
        ; Keeper_runtime_manifest.State_snapshot_sidecar_saved
        ]
    }
  ; { lane = "memory_context"
    ; mandatory_events =
        [ Keeper_runtime_manifest.Context_injected
        ; Keeper_runtime_manifest.Memory_flushed
        ]
    ; terminal_events = [ Keeper_runtime_manifest.Memory_flushed ]
    }
  ]

let lane_policy_for_lane lane =
  List.find_opt (fun policy -> String.equal policy.lane lane) lane_policies

let lane_mandatory_event_codes lane =
  match lane_policy_for_lane lane with
  | Some policy ->
    List.map Keeper_runtime_manifest.event_kind_to_string policy.mandatory_events
  | None -> []

let lane_terminal_event_codes lane =
  match lane_policy_for_lane lane with
  | Some policy ->
    List.map Keeper_runtime_manifest.event_kind_to_string policy.terminal_events
  | None -> []

let lane_mandatory_events_present scan lane =
  match lane_policy_for_lane lane with
  | Some policy ->
    List.for_all
      (fun event ->
         runtime_lens_event_count scan event > 0)
      policy.mandatory_events
  | None -> true

let lane_terminal_event_present scan lane =
  match lane_policy_for_lane lane with
  | Some policy ->
    List.exists
      (fun event ->
         runtime_lens_event_count scan event > 0)
      policy.terminal_events
  | None -> true

let runtime_lens_swimlane_completeness scan lane =
  let finished = lane_terminal_event_present scan lane in
  let complete = lane_mandatory_events_present scan lane && finished in
  if complete then "complete"
  else if finished then "finished"
  else if lane_mandatory_events_present scan lane then "mandatory_present"
  else "incomplete"
