open Keeper_types

let json_int_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Int n -> Some n
  | `Intlit raw -> (try Some (int_of_string raw) with Failure _ -> None)
  | _ -> None

let json_string_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let latest_decision_json ~(config : Coord.config) ~(keeper_name : string) :
    Yojson.Safe.t option =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    Keeper_memory.read_file_tail_lines path ~max_bytes:40000 ~max_lines:20
    |> List.rev
    |> List.find_map (fun line ->
           match Yojson.Safe.from_string line with
           | exception Yojson.Json_error _ -> None
           | (`Assoc _ as json) -> Some json
           | _ -> None)

let latest_tool_call_json ~(keeper_name : string) =
  Keeper_tool_call_log.read_latest ~keeper_name ()

let pending_approval_json ~(keeper_name : string) =
  match Keeper_approval_queue.list_pending_dashboard_json () with
  | `List entries ->
      entries
      |> List.filter (fun json ->
             String.equal keeper_name
               (Safe_ops.json_string ~default:"" "keeper_name" json))
      |> List.sort (fun left right ->
             Float.compare
               (Safe_ops.json_float ~default:0.0 "requested_at" right)
               (Safe_ops.json_float ~default:0.0 "requested_at" left))
      |> fun entries -> `List entries
  | _ -> `List []

let latest_turn_id ~(registry_entry : Keeper_registry.registry_entry option)
    (latest_decision : Yojson.Safe.t option) =
  match Option.bind latest_decision (json_int_opt_member "turn_id") with
  | Some _ as turn_id -> turn_id
  | None -> (
      match registry_entry with
      | Some { current_turn_observation = Some turn; _ } -> Some turn.turn_id
      | Some { last_completed_turn = Some turn; _ } -> Some turn.ct_turn_id
      | _ -> None)

let snapshot_json ~(config : Coord.config) ~(meta : keeper_meta) =
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path meta.name
  in
  let latest_decision = latest_decision_json ~config ~keeper_name:meta.name in
  let latest_tool_call = latest_tool_call_json ~keeper_name:meta.name in
  let pending_approvals = pending_approval_json ~keeper_name:meta.name in
  let pending_approval_count =
    match pending_approvals with
    | `List entries -> List.length entries
    | _ -> 0
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let runtime_phase =
    match registry_entry with
    | Some entry -> `String (Keeper_state_machine.phase_to_string entry.phase)
    | None -> `Null
  in
  let selected_model =
    Option.bind latest_decision (fun json ->
        let telemetry = Yojson.Safe.Util.member "telemetry" json in
        match json_string_opt_member "selected_model" telemetry with
        | Some _ as value -> value
        | None -> json_string_opt_member "model_used" telemetry)
  in
  let runtime_contract = Keeper_runtime_contract.runtime_contract_json meta in
  `Assoc
    [
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("generation", `Int meta.runtime.generation);
      ( "turn_id",
        match latest_turn_id ~registry_entry latest_decision with
        | Some turn_id -> `Int turn_id
        | None -> `Null );
      ("phase", runtime_phase);
      ("current_task_id", Json_util.string_opt_to_json (Keeper_runtime_contract.current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (Keeper_runtime_contract.primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("active_model", `String (Keeper_exec_status.active_model_label_of_meta meta));
      ("selected_model", Json_util.string_opt_to_json selected_model);
      ("runtime_contract", runtime_contract);
      ("runtime_blockers", `Assoc runtime_blocker_fields);
      ("pending_approval_count", `Int pending_approval_count);
      ("pending_approvals", pending_approvals);
      ("latest_decision", Option.value ~default:`Null latest_decision);
      ("latest_tool_call", Option.value ~default:`Null latest_tool_call);
      ( "last_event_bus_correlation",
        match registry_entry with
        | Some entry ->
            Json_util.string_opt_to_json entry.last_event_bus_correlation
        | None -> `Null );
    ]
