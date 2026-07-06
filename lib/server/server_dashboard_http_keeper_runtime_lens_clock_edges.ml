(** Runtime-lens clock-edge projection from existing manifest rows. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane


let clock_refs decision =
  match Json_util.assoc_member_opt "clock_refs" decision with
  | Some (`Assoc _ as obj) -> Some obj
  | _ -> None

let clock_string row key =
  match clock_refs row.Keeper_runtime_manifest.decision with
  | Some refs -> Json_util.get_string refs key
  | None -> None

let clock_string_non_empty row key =
  match clock_string row key with
  | Some value -> String_util.trim_to_option value
  | _ -> None

let first_non_empty values =
  List.find_map String_util.trim_to_option values

let first_string_opt values =
  values |> List.filter_map Fun.id |> first_non_empty

let basename_opt = function
  | None -> None
  | Some path ->
    let base = Filename.basename path in
    String_util.trim_to_option base

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
      Json_util.get_string decision "session_id"
      |> Option.map (fun session_id ->
        Printf.sprintf "checkpoint:%s:oas-%s" session_id (oas_turn_label row));
      basename_opt row.Keeper_runtime_manifest.links.checkpoint_path
      |> Option.map (fun base -> "checkpoint:" ^ base);
      Json_util.get_string decision "checkpoint_path"
      |> basename_opt
      |> Option.map (fun base -> "checkpoint:" ^ base);
    ]

let fallback_compaction_id row idx =
  Printf.sprintf "%s:keeper-%s:compaction-%d"
    row.Keeper_runtime_manifest.trace_id
    (turn_label row)
    idx

let event_started_at row =
  match row.Keeper_runtime_manifest.event with
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Runtime_routed
  | Keeper_runtime_manifest.Runtime_execution_built
  | Keeper_runtime_manifest.Provider_lane_resolved
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated
  | Keeper_runtime_manifest.Checkpoint_loaded ->
    Some row.Keeper_runtime_manifest.ts
  | Keeper_runtime_manifest.Runtime_completed
  | Keeper_runtime_manifest.Runtime_failed
  | Keeper_runtime_manifest.Provider_attempt_finished
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Checkpoint_saved
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Turn_finished ->
    None

let event_finished_at row =
  match row.Keeper_runtime_manifest.event with
  | Keeper_runtime_manifest.Runtime_completed
  | Keeper_runtime_manifest.Runtime_failed
  | Keeper_runtime_manifest.Provider_attempt_finished
  | Keeper_runtime_manifest.State_snapshot_sidecar_saved
  | Keeper_runtime_manifest.Working_state_sidecar_saved
  | Keeper_runtime_manifest.Checkpoint_saved
  | Keeper_runtime_manifest.Pre_dispatch_blocked
  | Keeper_runtime_manifest.Receipt_appended
  | Keeper_runtime_manifest.Turn_finished ->
    Some row.Keeper_runtime_manifest.ts
  | Keeper_runtime_manifest.Turn_started
  | Keeper_runtime_manifest.Phase_gate_decided
  | Keeper_runtime_manifest.Runtime_routed
  | Keeper_runtime_manifest.Runtime_execution_built
  | Keeper_runtime_manifest.Provider_lane_resolved
  | Keeper_runtime_manifest.Provider_attempt_started
  | Keeper_runtime_manifest.Context_injected
  | Keeper_runtime_manifest.Context_compacted
  | Keeper_runtime_manifest.Event_bus_correlated
  | Keeper_runtime_manifest.Checkpoint_loaded ->
    None

let event_source_clock = function
  | event ->
    Keeper_runtime_manifest.source_clock_of_event event
    |> Keeper_runtime_manifest.source_clock_to_string

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
    | Keeper_runtime_manifest.Provider_lane_resolved ->
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
  let event_bus_correlation_id =
    first_string_opt
      [
        clock_string row "event_bus_correlation_id";
        Json_util.get_string decision "correlation_id";
      ]
  in
  let event_bus_run_id =
    first_string_opt
      [
        clock_string row "event_bus_run_id";
        Json_util.get_string decision "run_id";
      ]
  in
  let event_bus_event_count =
    match event with
    | Keeper_runtime_manifest.Event_bus_correlated ->
      Json_util.get_int decision "event_count"
    | _ -> None
  in
  let event_bus_payload_kinds =
    match event with
    | Keeper_runtime_manifest.Event_bus_correlated ->
      Json_util.get_string_list decision "payload_kinds"
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
        Json_util.string_opt_to_json
          (first_string_opt [ clock_string row "started_at"; event_started_at row ]) );
      ( "finished_at",
        Json_util.string_opt_to_json
          (first_string_opt [ clock_string row "finished_at"; event_finished_at row ]) );
      ("trace_id", `String row.Keeper_runtime_manifest.trace_id);
      ("keeper_turn_id", Json_util.int_opt_to_json row.Keeper_runtime_manifest.keeper_turn_id);
      ("oas_turn_count", Json_util.int_opt_to_json row.Keeper_runtime_manifest.oas_turn_count);
      ("provider_attempt_id", Json_util.string_opt_to_json provider_attempt_id);
      ("tool_batch_id", Json_util.string_opt_to_json tool_batch_id);
      ("checkpoint_id", Json_util.string_opt_to_json checkpoint_id);
      ("compaction_id", Json_util.string_opt_to_json compaction_id);
      ("event_bus_correlation_id", Json_util.string_opt_to_json event_bus_correlation_id);
      ("event_bus_run_id", Json_util.string_opt_to_json event_bus_run_id);
      ("event_bus_event_count", Json_util.int_opt_to_json event_bus_event_count);
      ("event_bus_payload_kinds", Json_util.json_string_list event_bus_payload_kinds);
      ("parent_event_id", Json_util.string_opt_to_json (clock_string row "parent_event_id"));
      ("caused_by", Json_util.string_opt_to_json (clock_string row "caused_by"));
      ( "links",
        `Assoc
          [
            ("receipt_path", Json_util.string_opt_to_json row.Keeper_runtime_manifest.links.receipt_path);
            ("checkpoint_path", Json_util.string_opt_to_json row.Keeper_runtime_manifest.links.checkpoint_path);
            ( "tool_call_log_path",
              Json_util.string_opt_to_json row.Keeper_runtime_manifest.links.tool_call_log_path );
      ] );
    ]

let edge_string key edge = Json_util.get_string edge key
let edge_int key edge = Json_util.get_int edge key
let edge_string_list key edge = Json_util.get_string_list edge key

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
         | Some id when Option.is_some (String_util.trim_to_option id) -> List.mem id edge_id_set
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
