(** Cp_lifecycle_swarm_live core — resolution types, JSON helpers. *)

include Cp_snapshot

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let swarm_run_resolution_status_of_json json =
  match U.member "status" json with
  | `String ("continued" | "rerun" | "abandoned" as status) -> Some status
  | _ -> None

let read_swarm_run_resolution_json config run_id =
  find_swarm_live_artifact_json config run_id "resolution.json"

let swarm_run_resolution_entry_json ~status ~actor ~reason ?operation_id
    ?detachment_id ?note () =
  `Assoc
    [
      ("status", `String status);
      ("decided_by", `String actor);
      ("decided_at", `String (Types.now_iso ()));
      ("reason", `String reason);
      ("operation_id", option_to_json (fun value -> `String value) operation_id);
      ("detachment_id", option_to_json (fun value -> `String value) detachment_id);
      ("note", option_to_json (fun value -> `String value) note);
    ]

let record_swarm_run_resolution_json config ~run_id ~status ~actor ~reason
    ?operation_id ?detachment_id ?note () =
  let existing =
    match read_swarm_run_resolution_json config run_id with
    | Some (`Assoc _ as json) -> json
    | _ -> `Assoc []
  in
  let entry =
    swarm_run_resolution_entry_json ~status ~actor ~reason ?operation_id
      ?detachment_id ?note ()
  in
  let history =
    match U.member "history" existing with
    | `List rows -> rows @ [ entry ]
    | _ -> [ entry ]
  in
  let payload =
    `Assoc
      [
        ("run_id", `String run_id);
        ("status", `String status);
        ("decided_by", `String actor);
        ("decided_at", `String (Types.now_iso ()));
        ("reason", `String reason);
        ("operation_id", option_to_json (fun value -> `String value) operation_id);
        ("detachment_id", option_to_json (fun value -> `String value) detachment_id);
        ("note", option_to_json (fun value -> `String value) note);
        ("history", `List history);
      ]
  in
  let run_dir = Cp_paths.primary_swarm_live_run_dir config run_id in
  Room_utils.mkdir_p run_dir;
  Room_utils.write_json_local (Cp_paths.swarm_live_resolution_path config run_id)
    payload;
  payload

let swarm_live_json config ?run_id ?operation_id () =
  let room_id = Room.current_room_id config in
  let agents = Room.get_agents_raw config in
  let tasks = Room.get_tasks_raw config in
  let messages = Room.get_messages_raw config ~since_seq:0 ~limit:400 in
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let detachments = all_detachments config units operations in
  let decisions = all_policy_decisions config in
  let selected_operation =
    match operation_id with
    | Some value ->
        option_or_else
          (operation_by_id operations value)
          (fun () ->
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   String.equal operation.trace_id value))
    | None -> (
        match run_id with
        | Some value ->
            let tokens = run_tokens value in
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   value_matches_tokens tokens operation.operation_id
                   || value_matches_tokens tokens operation.objective
                   || option_matches_tokens tokens operation.note
                   || option_matches_tokens tokens operation.checkpoint_ref
                   || value_matches_tokens tokens operation.trace_id)
        | None ->
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   option_matches_tokens [ "swarm-live"; "agent swarm"; "harness" ]
                     operation.note
                   || value_matches_tokens [ "swarm-live"; "agent swarm"; "harness" ]
                        operation.objective))
  in
  let effective_run_id =
    match run_id with
    | Some value -> value
    | None -> (
        match selected_operation with
        | Some operation -> (
            let candidates =
              [
                operation.note;
                operation.checkpoint_ref;
              ]
              |> List.filter_map Fun.id
            in
            candidates |> List.find_map extract_run_id
            |> Option.value ~default:"swarm-live")
        | None -> "swarm-live")
  in
  let operation_started_at =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Room.parse_iso_time_opt operation.created_at)
  in
  let message_in_scope (message : Types.message) =
    match operation_started_at with
    | Some boundary -> timestamp_on_or_after ~boundary message.timestamp
    | None -> true
  in
  let task_in_scope (task : Types.task) =
    match operation_started_at with
    | Some boundary -> timestamp_on_or_after ~boundary task.created_at
    | None -> true
  in
  let scoped_tasks = tasks |> List.filter task_in_scope in
  let harness_summary =
    find_swarm_live_artifact_json config effective_run_id "swarm-live-summary.json"
  in
  let slot_telemetry =
    find_swarm_live_artifact_json config effective_run_id "slot-telemetry.json"
  in
  let runtime_doctor =
    Option.bind
      (find_swarm_live_artifact_path config effective_run_id "runtime-doctor.json")
      (fun path ->
        let run_dir = Filename.dirname path in
        read_runtime_doctor_json run_dir)
  in
  let live_slot_samples =
    match find_swarm_live_artifact_path config effective_run_id "slot-samples.jsonl" with
    | Some path when not (Option.is_some slot_telemetry) && Sys.file_exists path ->
        read_jsonl_local path
    | _ -> []
  in
  let worker_count_from_artifact =
    Option.bind harness_summary (fun json ->
        U.member "worker_count" json |> U.to_int_option)
  in
  let worker_count_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"worker_count"))
  in
  let required_final_markers =
    Option.bind harness_summary (fun json ->
        U.member "required_final_markers" json |> U.to_int_option)
  in
  let required_final_markers_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"required_final_markers"))
  in
  let min_hot_slots =
    Option.bind harness_summary (fun json ->
        U.member "min_hot_slots" json |> U.to_int_option)
  in
  let min_hot_slots_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"min_hot_slots"))
  in
  let min_hot_slots =
    Option.value min_hot_slots
      ~default:(Option.value min_hot_slots_from_operation ~default:10)
  in
  let plans =
    Agent_swarm_live_harness.build_worker_plans
      ~worker_count:
        (Option.value worker_count_from_artifact
           ~default:(Option.value worker_count_from_operation ~default:12))
      effective_run_id
  in
  let expected_workers = List.map (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name) plans in
  let operation_detachments =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           match selected_operation with
           | Some operation -> String.equal detachment.operation_id operation.operation_id
           | None -> true)
  in
  let matched_detachment =
    match selected_operation with
    | Some _ ->
        best_overlap expected_workers operation_detachments
          (fun (row : detachment_record) -> row.roster)
        |> Option.map fst
    | None ->
        best_overlap expected_workers detachments
          (fun (row : detachment_record) -> row.roster)
        |> Option.map fst
  in
  let matched_squad =
    match selected_operation with
