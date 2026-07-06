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

let runtime_lens_gap_json gap =
  `Assoc
    [
      ("code", `String gap.code);
      ("severity", `String gap.severity);
      ("lane", `String gap.lane);
      ("detail", Json_util.string_opt_to_json gap.detail);
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
  if runtime_lens_event_count scan Keeper_runtime_manifest.Checkpoint_saved > 0
  then "checkpoint_saved"
  else if
    runtime_lens_event_count scan Keeper_runtime_manifest.Checkpoint_loaded > 0
  then "checkpoint_loaded"
  else if
    scan.context_injected_count > 0
    || scan.context_compacted_event_count > 0
    || scan.event_bus_count > 0
  then "context"
  else "empty"

(** F8 + P5: lane mandatory event sets, terminal policy, and completion proof.

    [finished] = the lane's terminal event is present.
                 This means "the turn reached a terminal state for this lane",
                 not "the lane fulfilled its contract".

    [complete] = all mandatory events for the lane are present AND
                 the terminal event is present (or the lane has no terminal).
                 This means "the lane fulfilled its proof policy".

    [mandatory_present] = all mandatory events are present but the lane
                          has not reached its terminal event.

    [incomplete] = some mandatory events are missing.

    Separation of "terminal" from "complete" is required because a turn can
    finish (Turn_finished) while a lane still lacks mandatory events
    (e.g., missing checkpoint save). *)

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
  ; { lane = "masc_policy_runtime"
    ; mandatory_events = [ Keeper_runtime_manifest.Runtime_routed ]
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
        ; Keeper_runtime_manifest.Checkpoint_loaded
        ; Keeper_runtime_manifest.Checkpoint_saved
        ]
    ; terminal_events = [ Keeper_runtime_manifest.Checkpoint_saved ]
    }
  ]

let event_lane = function
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Turn_finished ->
    "keeper"
  | Keeper_runtime_manifest.Runtime_routed
  | Keeper_runtime_manifest.Runtime_execution_built
  | Keeper_runtime_manifest.Runtime_completed
  | Keeper_runtime_manifest.Runtime_failed
  | Keeper_runtime_manifest.Provider_lane_resolved ->
    "masc_policy_runtime"
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Provider_attempt_finished ->
    "provider"
  | Keeper_runtime_manifest.Checkpoint_loaded
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Checkpoint_saved ->
    "oas_agent"
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated ->
    "memory_context"

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
  | Some { terminal_events = []; _ } -> false
  | Some policy ->
    List.exists
      (fun event ->
         runtime_lens_event_count scan event > 0)
      policy.terminal_events
  | None -> true

let runtime_lens_swimlane_completeness scan lane =
  let mandatory_present = lane_mandatory_events_present scan lane in
  let finished = lane_terminal_event_present scan lane in
  let terminal_required =
    match lane_policy_for_lane lane with
    | Some { terminal_events = []; _ } -> false
    | Some _ | None -> true
  in
  let complete = mandatory_present && ((not terminal_required) || finished) in
  if complete then "complete"
  else if finished then "finished"
  else if mandatory_present then "mandatory_present"
  else "incomplete"

let runtime_lens_swimlane_rendered_completeness scan lane event_count =
  if String.equal lane "tool_runtime" && event_count = 0
  then "not_observed"
  else runtime_lens_swimlane_completeness scan lane

let runtime_lens_swimlane_json scan gaps ~lane ~label ~events
    ~terminal_status ~synthetic_events =
  let gap_codes = runtime_lens_gap_codes_for_lane gaps lane in
  let standard_event_count =
    events
    |> List.fold_left
         (fun total event -> total + runtime_lens_event_count scan event)
         0
  in
  let synthetic_event_count =
    List.fold_left (fun total (_, count) -> total + count) 0 synthetic_events
  in
  let event_count = standard_event_count + synthetic_event_count in
  let standard_events_json = runtime_lens_events_json scan events in
  let synthetic_events_json =
    List.map
      (fun (name, count) ->
         `Assoc [("event", `String name); ("count", `Int count)])
      synthetic_events
  in
  let all_events =
    match standard_events_json with
    | `List events -> `List (events @ synthetic_events_json)
    | other -> other
  in
  let dag_edges_json =
    List.map
      (fun (parent_event_id, event_id) ->
         `Assoc
           [
             ("parent_event_id", `String parent_event_id);
             ("event_id", `String event_id);
           ])
      scan.dag_edges
  in
  `Assoc
    [
      ("lane", `String lane);
      ("label", `String label);
      ("event_count", `Int event_count);
      ("terminal_status", `String terminal_status);
      ( "completeness",
        `String
          (runtime_lens_swimlane_rendered_completeness scan lane event_count) );
      ("gap_codes", Json_util.json_string_list gap_codes);
      ( "gap_badge",
        match gap_codes with
        | code :: _ -> `String code
        | [] -> `Null );
      ("events", all_events);
      ("dag_edges", `List dag_edges_json);
    ]
