(** Runtime-lens clock-edge projection from existing manifest rows. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let json_string_opt = function
  | None -> `Null
  | Some value -> `String value

let json_int_opt = function
  | None -> `Null
  | Some value -> `Int value

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let json_string_list_member key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
    List.filter_map
      (function
        | `String value when String.trim value <> "" -> Some value
        | _ -> None)
      items
  | _ -> []

let event_lane = function
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Turn_finished ->
    "keeper"
  | Keeper_runtime_manifest.Cascade_routed
  | Keeper_runtime_manifest.Provider_lane_resolved ->
    "masc_policy_cascade"
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Provider_attempt_finished ->
    "provider"
  | Keeper_runtime_manifest.Tool_surface_selected
  | Keeper_runtime_manifest.Tool_lineage_recorded -> "tool_runtime"
  | Keeper_runtime_manifest.Checkpoint_loaded
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Checkpoint_saved ->
    "oas_agent"
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated
  | Keeper_runtime_manifest.Memory_injected
  | Keeper_runtime_manifest.Memory_flushed ->
    "memory_context"

let clock_refs decision =
  match Yojson.Safe.Util.member "clock_refs" decision with
  | `Assoc _ as obj -> Some obj
  | _ -> None

let clock_string row key =
  match clock_refs row.Keeper_runtime_manifest.decision with
  | Some refs -> json_string_member_opt key refs
  | None -> None

let clock_string_non_empty row key =
  match clock_string row key with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let first_non_empty values =
  List.find_opt (fun value -> String.trim value <> "") values

let first_string_opt values =
  values |> List.filter_map Fun.id |> first_non_empty

let basename_opt = function
  | None -> None
  | Some path ->
    let base = Filename.basename path in
    if String.trim base = "" then None else Some base

let turn_label row =
  match row.Keeper_runtime_manifest.keeper_turn_id with
  | Some value -> string_of_int value
  | None -> "unknown"

let oas_turn_label row =
  match row.Keeper_runtime_manifest.oas_turn_count with
  | Some value -> string_of_int value
  | None -> "0"

let fallback_edge_id row idx =
  Printf.sprintf "%s:%s:%d" row.Keeper_runtime_manifest.trace_id
    (Keeper_runtime_manifest.event_kind_to_string row.Keeper_runtime_manifest.event)
    idx

let fallback_tool_batch_id row =
  Printf.sprintf "%s:keeper-%s:tool-batch-oas-%s"
    row.Keeper_runtime_manifest.trace_id
    (turn_label row)
    (oas_turn_label row)

let fallback_provider_attempt_id row attempt_index =
  Printf.sprintf "%s:keeper-%s:provider-attempt-%d"
    row.Keeper_runtime_manifest.trace_id
    (turn_label row)
    attempt_index

let fallback_checkpoint_id row =
  let decision = row.Keeper_runtime_manifest.decision in
  first_string_opt
    [
      json_string_member_opt "session_id" decision
      |> Option.map (fun session_id ->
        Printf.sprintf "checkpoint:%s:oas-%s" session_id (oas_turn_label row));
      basename_opt row.Keeper_runtime_manifest.links.checkpoint_path
      |> Option.map (fun base -> "checkpoint:" ^ base);
      json_string_member_opt "checkpoint_path" decision
      |> basename_opt
      |> Option.map (fun base -> "checkpoint:" ^ base);
    ]

let fallback_compaction_id row idx =
  Printf.sprintf "%s:keeper-%s:compaction-%d"
    row.Keeper_runtime_manifest.trace_id
    (turn_label row)
    idx

let fallback_memory_injection_id row =
  Printf.sprintf "%s:keeper-%s:memory-oas-%s"
    row.Keeper_runtime_manifest.trace_id
    (turn_label row)
    (oas_turn_label row)

let event_started_at row =
  match row.Keeper_runtime_manifest.event with
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Cascade_routed
  | Keeper_runtime_manifest.Tool_surface_selected
  | Keeper_runtime_manifest.Provider_lane_resolved
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated
  | Keeper_runtime_manifest.Memory_injected
  | Keeper_runtime_manifest.Checkpoint_loaded ->
    Some row.Keeper_runtime_manifest.ts
  | Keeper_runtime_manifest.Provider_attempt_finished
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Memory_flushed
  | Keeper_runtime_manifest.Checkpoint_saved
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Tool_lineage_recorded
  | Keeper_runtime_manifest.Turn_finished ->
    None

let event_finished_at row =
  match row.Keeper_runtime_manifest.event with
  | Keeper_runtime_manifest.Provider_attempt_finished
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Memory_flushed
  | Keeper_runtime_manifest.Checkpoint_saved
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Tool_lineage_recorded
  | Keeper_runtime_manifest.Turn_finished ->
    Some row.Keeper_runtime_manifest.ts
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Cascade_routed
  | Keeper_runtime_manifest.Tool_surface_selected
  | Keeper_runtime_manifest.Provider_lane_resolved
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated
  | Keeper_runtime_manifest.Memory_injected
  | Keeper_runtime_manifest.Checkpoint_loaded ->
    None

let event_source_clock = function
  | Keeper_runtime_manifest.Event_bus_correlated -> "oas_event_bus"
  | _ -> "wall"

let clock_edge_json ~idx ~provider_attempt_index row =
  let event = row.Keeper_runtime_manifest.event in
  let decision = row.Keeper_runtime_manifest.decision in
  let explicit_provider_attempt_id = clock_string row "provider_attempt_id" in
  let provider_attempt_id =
    match event with
    | Keeper_runtime_manifest.Provider_attempt_started
    | Keeper_runtime_manifest.Provider_attempt_finished ->
      first_string_opt
        [
          explicit_provider_attempt_id;
          Some (fallback_provider_attempt_id row provider_attempt_index);
        ]
    | _ -> explicit_provider_attempt_id
  in
  let tool_batch_id =
    match event with
    | Keeper_runtime_manifest.Tool_surface_selected
    | Keeper_runtime_manifest.Provider_lane_resolved
    | Keeper_runtime_manifest.Tool_lineage_recorded ->
      first_string_opt [ clock_string row "tool_batch_id"; Some (fallback_tool_batch_id row) ]
    | _ -> clock_string row "tool_batch_id"
  in
  let checkpoint_id =
  match event with
  | Keeper_runtime_manifest.Checkpoint_loaded
  | Keeper_runtime_manifest.Checkpoint_saved
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved ->
    first_string_opt [ clock_string row "checkpoint_id"; fallback_checkpoint_id row ]
    | _ -> clock_string row "checkpoint_id"
  in
  let compaction_id =
    match event with
    | Keeper_runtime_manifest.Context_compacted
    | Keeper_runtime_manifest.Event_bus_correlated ->
      first_string_opt [ clock_string row "compaction_id"; Some (fallback_compaction_id row idx) ]
    | _ -> clock_string row "compaction_id"
  in
  let memory_injection_id =
    match event with
    | Keeper_runtime_manifest.Memory_injected
    | Keeper_runtime_manifest.Memory_flushed ->
      first_string_opt
        [ clock_string row "memory_injection_id"; Some (fallback_memory_injection_id row) ]
    | _ -> clock_string row "memory_injection_id"
  in
  let event_bus_correlation_id =
    first_string_opt
      [
        clock_string row "event_bus_correlation_id";
        json_string_member_opt "correlation_id" decision;
      ]
  in
  let event_bus_run_id =
    first_string_opt
      [
        clock_string row "event_bus_run_id";
        json_string_member_opt "run_id" decision;
      ]
  in
  let event_bus_event_count =
    match event with
    | Keeper_runtime_manifest.Event_bus_correlated ->
      json_int_member_opt "event_count" decision
    | _ -> None
  in
  let event_bus_payload_kinds =
    match event with
    | Keeper_runtime_manifest.Event_bus_correlated ->
      json_string_list_member "payload_kinds" decision
    | _ -> []
  in
  `Assoc
    [
      ( "edge_id",
        `String
          (match
             first_string_opt
               [
                 clock_string_non_empty row "edge_id";
                 clock_string_non_empty row "event_id";
               ]
           with
           | Some value -> value
           | None -> fallback_edge_id row idx) );
      ( "lane",
        `String
          (match clock_string_non_empty row "lane" with
           | Some value -> value
           | None -> event_lane event) );
      ("event", `String (Keeper_runtime_manifest.event_kind_to_string event));
      ("status", `String row.Keeper_runtime_manifest.status);
      ( "observed_at",
        `String
          (match clock_string_non_empty row "observed_at" with
           | Some value -> value
           | None -> row.Keeper_runtime_manifest.ts) );
      ( "source_clock",
        `String
          (match clock_string_non_empty row "source_clock" with
           | Some value -> value
           | None -> event_source_clock event) );
      ( "started_at",
        json_string_opt
          (first_string_opt [ clock_string row "started_at"; event_started_at row ]) );
      ( "finished_at",
        json_string_opt
          (first_string_opt [ clock_string row "finished_at"; event_finished_at row ]) );
      ("trace_id", `String row.Keeper_runtime_manifest.trace_id);
      ("keeper_turn_id", json_int_opt row.Keeper_runtime_manifest.keeper_turn_id);
      ("oas_turn_count", json_int_opt row.Keeper_runtime_manifest.oas_turn_count);
      ("provider_attempt_id", json_string_opt provider_attempt_id);
      ("tool_batch_id", json_string_opt tool_batch_id);
      ("checkpoint_id", json_string_opt checkpoint_id);
      ("compaction_id", json_string_opt compaction_id);
      ("memory_injection_id", json_string_opt memory_injection_id);
      ("event_bus_correlation_id", json_string_opt event_bus_correlation_id);
      ("event_bus_run_id", json_string_opt event_bus_run_id);
      ("event_bus_event_count", json_int_opt event_bus_event_count);
      ("event_bus_payload_kinds", json_string_list event_bus_payload_kinds);
      ("parent_event_id", json_string_opt (clock_string row "parent_event_id"));
      ("caused_by", json_string_opt (clock_string row "caused_by"));
      ( "links",
        `Assoc
          [
            ("receipt_path", json_string_opt row.Keeper_runtime_manifest.links.receipt_path);
            ("checkpoint_path", json_string_opt row.Keeper_runtime_manifest.links.checkpoint_path);
            ( "tool_call_log_path",
              json_string_opt row.Keeper_runtime_manifest.links.tool_call_log_path );
      ] );
    ]

let edge_string key edge = json_string_member_opt key edge
let edge_int key edge = json_int_member_opt key edge
let edge_string_list key edge = json_string_list_member key edge

let clock_edge_jsons scan =
  let provider_attempt_index = ref 0 in
  let edges =
    scan.returned_rows
    |> queue_to_list
    |> List.mapi (fun idx row ->
      let provider_index =
        match row.Keeper_runtime_manifest.event with
        | Keeper_runtime_manifest.Provider_attempt_started ->
          incr provider_attempt_index;
          !provider_attempt_index
        | Keeper_runtime_manifest.Provider_attempt_finished ->
          max 1 !provider_attempt_index
        | _ -> max 1 !provider_attempt_index
      in
      clock_edge_json ~idx ~provider_attempt_index:provider_index row)
  in
  (* F7: DAG causality — build edge_id set once, then verify each edge's parent. *)
  let edge_id_set =
    edges
    |> List.filter_map (fun edge -> edge_string "edge_id" edge)
    |> List.fold_left (fun acc value ->
         let value = String.trim value in
         if value = "" then acc else value :: acc)
         []
  in
  edges
  |> List.map (fun edge ->
       let parent_id = edge_string "parent_event_id" edge in
       let causality_verified =
         match parent_id with
         | Some id when String.trim id <> "" -> List.mem id edge_id_set
         | _ -> true
       in
       match edge with
       | `Assoc fields ->
         `Assoc
           (fields
            @ [ ("causality_verified", `Bool causality_verified)
              ; ( "causality_driven",
                  `Bool (edge_string "parent_event_id" edge <> None || edge_string "caused_by" edge <> None) )
              ])
       | other -> other)

let runtime_lens_clock_edges_json scan =
  clock_edge_jsons scan |> fun edges -> `List edges
