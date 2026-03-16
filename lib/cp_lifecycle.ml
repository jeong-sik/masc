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
    | Some operation ->
        option_or_else
          (lookup_unit units operation.assigned_unit_id)
          (fun () ->
            Option.bind matched_detachment (fun (detachment : detachment_record) ->
                lookup_unit units detachment.assigned_unit_id))
    | None ->
        option_or_else
          (Option.bind matched_detachment (fun (detachment : detachment_record) ->
               lookup_unit units detachment.assigned_unit_id))
          (fun () ->
            units
            |> List.filter (fun (unit : unit_record) -> unit.kind = Squad)
            |> fun rows ->
            best_overlap expected_workers rows
              (fun (unit : unit_record) -> unit.roster)
            |> Option.map fst)
  in
  let pending_decisions =
    decisions
    |> List.filter (fun (decision : policy_decision_record) ->
           String.equal decision.status "pending"
           &&
           match selected_operation with
           | Some operation -> decision.operation_id = Some operation.operation_id
           | None -> true)
  in
  let relevant_traces =
    list_traces_json config ?operation_id:(Option.map (fun (operation : operation_record) -> operation.operation_id) selected_operation)
      ~limit:12 ()
    |> U.member "events"
    |> U.to_list
  in
  let message_matches_run (message : Types.message) =
    value_matches_tokens (run_tokens effective_run_id) message.content
    || List.mem message.from_agent expected_workers
  in
  let matching_messages =
    messages
    |> List.filter (fun message -> message_in_scope message && message_matches_run message)
    |> List.sort (fun (left : Types.message) (right : Types.message) -> compare right.seq left.seq)
  in
  let recent_messages =
    matching_messages
    |> List.filteri (fun idx _ -> idx < 12)
    |> List.rev
  in
  let message_contains ~from_agent needle =
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && string_contains ~needle message.content)
      matching_messages
  in
  let message_starts_with ~from_agent prefix =
    let prefix_len = String.length prefix in
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && String.length message.content >= prefix_len
        && String.sub message.content 0 prefix_len = prefix)
      matching_messages
  in
  let task_by_id =
    List.map (fun (task : Types.task) -> (task.id, task)) tasks
  in
  let find_agent name =
    agents |> List.find_opt (fun (agent : Types.agent) -> String.equal agent.name name)
  in
  let find_task_title task_id =
    List.assoc_opt task_id task_by_id |> Option.map (fun (task : Types.task) -> task.title)
  in
  let find_task_status task_id =
    List.assoc_opt task_id task_by_id
    |> Option.map (fun (task : Types.task) -> Types.string_of_task_status task.task_status)
  in
  let task_assignee (task : Types.task) =
    match task.task_status with
    | Types.Claimed { assignee; _ }
    | Types.InProgress { assignee; _ }
    | Types.Done { assignee; _ } -> Some assignee
    | Types.Todo | Types.Cancelled _ -> None
  in
  let task_done (task : Types.task) =
    match task.task_status with
    | Types.Done _ -> true
    | _ -> false
  in
  let worker_rows =
    plans
    |> List.map (fun (plan : Agent_swarm_live_harness.worker_plan) ->
           let agent = find_agent plan.name in
           let current_task = Option.bind agent (fun (value : Types.agent) -> value.current_task) in
           let heartbeat_age_sec =
             Option.bind agent (fun (value : Types.agent) -> float_age_seconds value.last_seen)
           in
           let task_matches_run =
             match current_task with
             | Some task_id -> (
                 match List.assoc_opt task_id task_by_id with
                 | Some task ->
                     value_matches_tokens (run_tokens effective_run_id) task.title
                     || value_matches_tokens [ plan.name ] task.title
                 | None -> false)
             | None -> false
           in
           let assigned_task =
             scoped_tasks
             |> List.find_opt (fun (task : Types.task) ->
                    match task_assignee task with
                    | Some assignee when String.equal assignee plan.name ->
                        value_matches_tokens (run_tokens effective_run_id) task.title
                        || value_matches_tokens [ plan.name ] task.title
                    | _ -> false)
           in
           let last_message =
             recent_messages
             |> List.find_opt (fun (message : Types.message) ->
                    String.equal message.from_agent plan.name)
           in
           let claim_marker_seen =
             message_contains ~from_agent:plan.name plan.claim_marker
           in
           let done_marker_seen =
             message_contains ~from_agent:plan.name plan.done_marker
           in
           let final_marker_seen =
             message_starts_with ~from_agent:plan.name plan.final_marker
           in
           let runtime_assisted_final_marker_seen =
             List.exists
               (fun (message : Types.message) ->
                 String.equal message.from_agent plan.name
                 && string_contains
                      ~needle:
                        (Printf.sprintf
                           "RUNTIME_ASSISTED_FINAL_MARKER expected=%s"
                           plan.final_marker)
                      message.content)
               matching_messages
           in
           let completed_task =
             if done_marker_seen || final_marker_seen
                || runtime_assisted_final_marker_seen
             then
               tasks
               |> List.find_opt (fun (task : Types.task) ->
                      match task_assignee task with
                      | Some assignee when String.equal assignee plan.name ->
                          value_matches_tokens (run_tokens effective_run_id) task.title
                      | _ -> false)
             else
               None
           in
           let joined =
             Option.is_some agent
             || Option.is_some assigned_task
             || Option.is_some completed_task
             || Option.is_some last_message
             || claim_marker_seen
             || done_marker_seen
             || final_marker_seen
             || runtime_assisted_final_marker_seen
           in
           let task_bound =
             task_matches_run || Option.is_some assigned_task
             || Option.is_some completed_task
           in
           let bound_task_id =
             option_first_some (if task_matches_run then current_task else None)
               (option_first_some
                  (Option.map (fun (task : Types.task) -> task.id) assigned_task)
                  (Option.map (fun (task : Types.task) -> task.id) completed_task))
           in
           let bound_task_title =
             match bound_task_id with
             | Some value -> find_task_title value
             | None ->
                 option_first_some
                   (Option.map (fun (task : Types.task) -> task.title) assigned_task)
                   (Option.map (fun (task : Types.task) -> task.title) completed_task)
           in
           let bound_task_status =
             match bound_task_id with
             | Some value -> find_task_status value
             | None ->
                 option_first_some
                   (assigned_task
                    |> Option.map (fun (task : Types.task) ->
                           Types.string_of_task_status task.task_status))
                   (completed_task
                    |> Option.map (fun (task : Types.task) ->
                           Types.string_of_task_status task.task_status))
           in
           let completed =
             match option_first_some assigned_task completed_task with
             | Some task -> task_done task
             | None ->
                 done_marker_seen
                 && (final_marker_seen || runtime_assisted_final_marker_seen)
           in
           let heartbeat_fresh =
             match heartbeat_age_sec with
             | Some age -> age <= Room.heartbeat_timeout_seconds
             | None -> completed
           in
           `Assoc
             [
               ("name", `String plan.name);
               ("role", `String (Agent_swarm_live_harness.string_of_worker_role plan.role));
               ("lane", `String (Agent_swarm_live_harness.string_of_fixture_lane plan.lane));
               ("joined", `Bool joined);
               ("live_presence", `Bool (Option.is_some agent));
               ("completed", `Bool completed);
               ( "status",
                 match agent with
                 | Some value -> `String (Types.string_of_agent_status value.status)
                 | None -> `String "offline" );
               ("current_task", match current_task with Some value -> `String value | None -> `Null);
               ("bound_task_id", match bound_task_id with Some value -> `String value | None -> `Null);
               ("bound_task_title", match bound_task_title with Some value -> `String value | None -> `Null);
               ("bound_task_status", match bound_task_status with Some value -> `String value | None -> `Null);
               ("current_task_matches_run", `Bool task_bound);
               ("squad_member", `Bool (option_exists (fun (unit : unit_record) -> List.mem plan.name unit.roster) matched_squad));
               ("detachment_member", `Bool (option_exists (fun (detachment : detachment_record) -> List.mem plan.name detachment.roster) matched_detachment));
               ( "last_seen",
                 match agent with
                 | Some value -> `String value.last_seen
                 | None -> `Null );
               ("heartbeat_age_sec", match heartbeat_age_sec with Some value -> `Float value | None -> `Null);
               ("heartbeat_fresh", `Bool heartbeat_fresh);
               ("claim_marker_seen", `Bool claim_marker_seen);
               ("done_marker_seen", `Bool done_marker_seen);
               ("final_marker_seen", `Bool final_marker_seen);
               ("runtime_assisted_final_marker_seen", `Bool runtime_assisted_final_marker_seen);
               ("claim_marker", `String plan.claim_marker);
               ("done_marker", `String plan.done_marker);
               ("final_marker", `String plan.final_marker);
               ( "last_message",
                 match last_message with
                 | Some message ->
                     `Assoc
                       [
                         ("seq", `Int message.seq);
                         ("content", `String message.content);
                         ("timestamp", `String message.timestamp);
                       ]
                 | None -> `Null );
             ])
  in
  let joined_workers =
    count_true worker_rows (fun row ->
        U.member "joined" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let current_task_bound =
    count_true worker_rows (fun row ->
        U.member "bound_task_id" row <> `Null
        && U.member "current_task_matches_run" row |> U.to_bool_option
           |> Option.value ~default:false)
  in
  let fresh_heartbeats =
    count_true worker_rows (fun row ->
        U.member "heartbeat_fresh" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let claim_markers_seen =
    count_true worker_rows (fun row ->
        U.member "claim_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let done_markers_seen =
    count_true worker_rows (fun row ->
        U.member "done_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let final_markers_seen =
    count_true worker_rows (fun row ->
        U.member "final_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let runtime_assisted_final_markers_seen =
    count_true worker_rows (fun row ->
        U.member "runtime_assisted_final_marker_seen" row |> U.to_bool_option
        |> Option.value ~default:false)
  in
  let completed_workers =
    count_true worker_rows (fun row ->
        match U.member "bound_task_status" row |> U.to_string_option with
        | Some status -> String.equal status "done"
        | None -> false)
  in
  let artifact_completed_workers =
    Option.bind harness_summary (fun json ->
        U.member "completed_workers" json |> U.to_int_option)
  in
  let artifact_final_markers_seen =
    Option.bind harness_summary (fun json ->
        U.member "final_markers_seen" json |> U.to_int_option)
  in
  let artifact_runtime_assisted_final_markers_seen =
    Option.bind harness_summary (fun json ->
        U.member "runtime_assisted_final_markers" json |> U.to_int_option)
  in
  let effective_completed_workers =
    match selected_operation with
    | Some _ -> completed_workers
    | None ->
        if completed_workers > 0 then completed_workers
        else Option.value artifact_completed_workers ~default:0
  in
  let effective_final_markers_seen =
    match selected_operation with
    | Some _ -> final_markers_seen
    | None ->
        if final_markers_seen > 0 then final_markers_seen
        else Option.value artifact_final_markers_seen ~default:0
  in
  let effective_runtime_assisted_final_markers_seen =
    match selected_operation with
    | Some _ -> runtime_assisted_final_markers_seen
    | None ->
        if runtime_assisted_final_markers_seen > 0 then
          runtime_assisted_final_markers_seen
        else
          Option.value artifact_runtime_assisted_final_markers_seen ~default:0
  in
  let live_sample_count = List.length live_slot_samples in
  let live_peak_hot_slots =
    live_slot_samples
    |> List.fold_left
         (fun acc row ->
           let value =
             U.member "active_slots" row |> U.to_int_option |> Option.value ~default:0
           in
           max acc value)
         0
  in
  let live_last_sample = List.rev live_slot_samples |> list_hd_opt in
  let live_total_slots =
    option_or_else
      (Option.bind live_last_sample (fun row -> U.member "total_slots" row |> U.to_int_option))
      (fun () ->
        live_slot_samples
        |> List.find_map (fun row -> U.member "total_slots" row |> U.to_int_option))
    |> Option.value ~default:0
  in
  let live_ctx_per_slot =
    option_or_else
      (Option.bind live_last_sample (fun row -> U.member "ctx_per_slot" row |> U.to_int_option))
      (fun () ->
        live_slot_samples
        |> List.find_map (fun row -> U.member "ctx_per_slot" row |> U.to_int_option))
    |> Option.value ~default:0
  in
  let live_active_slots_now =
    Option.bind live_last_sample (fun row -> U.member "active_slots" row |> U.to_int_option)
    |> Option.value ~default:0
  in
  let live_last_sample_at =
    Option.bind live_last_sample (fun row -> U.member "timestamp" row |> U.to_string_option)
  in
  let live_telemetry_timeline =
    live_slot_samples
    |> List.rev
    |> List.filteri (fun idx _ -> idx < 60)
    |> List.rev
    |> List.map (fun row ->
           `Assoc
             [
               ("timestamp", option_or_else (U.member "timestamp" row |> U.to_string_option) (fun () -> Some "") |> Option.value ~default:"" |> fun value -> `String value);
               ( "active_slots",
                 `Int
                   (U.member "active_slots" row |> U.to_int_option
                   |> Option.value ~default:0) );
               ( "active_slot_ids",
                 match U.member "active_slot_ids" row with
                 | `List values -> `List values
                 | _ -> `List [] );
             ])
  in
  let total_slots =
    Option.bind slot_telemetry (fun json ->
        U.member "total_slots" json |> U.to_int_option)
    |> Option.value ~default:live_total_slots
  in
  let ctx_per_slot =
    Option.bind slot_telemetry (fun json ->
        U.member "ctx_per_slot" json |> U.to_int_option)
    |> Option.value ~default:live_ctx_per_slot
  in
  let active_slots_now =
    Option.bind slot_telemetry (fun json ->
        U.member "active_slots_now" json |> U.to_int_option)
    |> Option.value ~default:live_active_slots_now
  in
  let peak_hot_slots =
    Option.bind slot_telemetry (fun json ->
        U.member "peak_active_slots" json |> U.to_int_option)
    |> Option.value ~default:live_peak_hot_slots
  in
  let sample_count =
    Option.bind slot_telemetry (fun json ->
        U.member "sample_count" json |> U.to_int_option)
    |> Option.value ~default:live_sample_count
  in
  let hot_window_ok =
    Option.bind slot_telemetry (fun json ->
        U.member "hot_window_ok" json |> U.to_bool_option)
    |> Option.value ~default:(live_peak_hot_slots >= min_hot_slots)
  in
  let last_sample_at =
    option_or_else
      (Option.bind slot_telemetry (fun json ->
           U.member "last_sample_at" json |> U.to_string_option))
      (fun () -> live_last_sample_at)
  in
  let slot_url =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.slot_url))
      (fun () ->
         Option.bind slot_telemetry (fun json ->
             U.member "slot_url" json |> U.to_string_option))
  in
  let telemetry_timeline =
    match slot_telemetry with
    | Some json -> (
        match U.member "timeline" json with
        | `List rows -> rows
        | _ -> [])
    | None -> live_telemetry_timeline
  in
  let provider_base_url =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_base_url)
  in
  let provider_reachable =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.provider_reachable))
      (fun () ->
         if total_slots > 0 || sample_count > 0 then Some true else None)
  in
  let provider_status_code =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_status_code)
  in
  let provider_model_id =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_model_id)
  in
  let actual_model_id =
    Option.bind runtime_doctor (fun doctor -> doctor.actual_model_id)
  in
  let expected_slots =
    Option.bind runtime_doctor (fun doctor -> doctor.expected_slots)
  in
  let actual_slots =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.actual_slots))
      (fun () -> Some total_slots)
  in
  let expected_ctx =
    Option.bind runtime_doctor (fun doctor -> doctor.expected_ctx)
  in
  let actual_ctx =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.actual_ctx))
      (fun () -> Some ctx_per_slot)
  in
  let configured_capacity =
    Option.bind runtime_doctor (fun doctor -> doctor.configured_capacity)
  in
  let slot_reachable =
    Option.bind runtime_doctor (fun doctor -> doctor.slot_reachable)
  in
  let slot_status_code =
    Option.bind runtime_doctor (fun doctor -> doctor.slot_status_code)
  in
  let runtime_detail =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.detail))
      (fun () -> Option.bind runtime_doctor (fun doctor -> doctor.provider_error))
  in
  let runtime_checked_at =
    Option.bind runtime_doctor (fun doctor -> doctor.checked_at)
  in
  let runtime_blocker =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.runtime_blocker))
      (fun () ->
         match provider_reachable with
         | Some false -> Some "provider_unreachable"
         | _ -> (
             match provider_model_id, actual_model_id with
             | Some expected, Some actual when not (String.equal expected actual) ->
                 Some "provider_model_mismatch"
             | _ -> (
                 match expected_ctx, actual_ctx with
                 | Some expected, Some actual when expected <> actual ->
                     Some "ctx_mismatch"
                 | _ -> (
                     match expected_slots, actual_slots with
                     | Some expected, Some actual when actual < expected ->
                         Some "slot_count_insufficient"
                     | _ -> None))))
  in
  let detachment_exists = matched_detachment <> None in
  let operation_ready =
    match selected_operation with
    | Some operation ->
        not
          (operation.status = Cancelled || operation.status = Failed)
    | None -> false
  in
  let detachment_roster_matches =
    match matched_detachment with
    | Some detachment ->
        let left = List.sort String.compare detachment.roster in
        let right = List.sort String.compare expected_workers in
        left = right
    | None -> false
  in
  let expected_count = List.length expected_workers in
  let required_final_markers =
    Option.value required_final_markers
      ~default:
        (Option.value required_final_markers_from_operation
           ~default:expected_count)
  in
  let pass_hot_concurrency =
    peak_hot_slots >= min_hot_slots
    && hot_window_ok
  in
  let pass_end_to_end =
    joined_workers = expected_count
    && current_task_bound = expected_count
    && fresh_heartbeats = expected_count
    && effective_completed_workers = expected_count
  in
  let checklist =
    [
      checklist_item ~id:"active-operation" ~title:"Active operation exists"
        ~status:(if operation_ready then "pass" else "fail")
        ~detail:
          (match selected_operation with
          | Some operation -> Printf.sprintf "%s · %s" operation.operation_id (string_of_operation_status operation.status)
          | None -> "No managed operation matches this run yet.")
        ~next_tool:"masc_operation_start";
      checklist_item ~id:"detachment-materialized" ~title:"Detachment materialized after tick"
        ~status:(if detachment_exists then "pass" else "fail")
        ~detail:
          (match matched_detachment with
          | Some detachment -> Printf.sprintf "%s · %s" detachment.detachment_id detachment.status
          | None -> "No matching detachment yet.")
        ~next_tool:"masc_dispatch_tick";
      checklist_item ~id:"worker-joins" ~title:"Expected workers joined"
        ~status:(if joined_workers = expected_count then "pass" else "fail")
        ~detail:(Printf.sprintf "%d / %d workers have live or recorded run evidence" joined_workers expected_count)
        ~next_tool:"masc_join";
      checklist_item ~id:"current-task" ~title:"Workers have current_task bindings"
        ~status:(if current_task_bound = expected_count then "pass" else "fail")
        ~detail:(Printf.sprintf "%d / %d workers have run-scoped task ownership or clean completion evidence" current_task_bound expected_count)
        ~next_tool:"masc_plan_set_task";
      checklist_item ~id:"final-markers" ~title:"Model final markers observed"
        ~status:(if effective_final_markers_seen >= required_final_markers then "pass" else "warn")
        ~detail:
          (Printf.sprintf
             "%d / %d model markers seen; runtime-assisted=%d; completed=%d / %d; detachment roster match=%s"
             effective_final_markers_seen required_final_markers
             effective_runtime_assisted_final_markers_seen
             effective_completed_workers expected_count
             (if detachment_roster_matches then "yes" else "no"))
        ~next_tool:"masc_observe_traces";
      checklist_item ~id:"hot-slots" ~title:"Peak hot slots reached threshold"
        ~status:(if pass_hot_concurrency then "pass" else "fail")
        ~detail:
          (Printf.sprintf "peak hot slots=%d, active now=%d, ctx=%d, samples=%d"
             peak_hot_slots active_slots_now ctx_per_slot sample_count)
        ~next_tool:"restart llama hot profile";
    ]
  in
  let blockers = ref [] in
  if not operation_ready then
    blockers :=
      blocker_item ~code:"missing-operation" ~severity:"bad"
        ~title:"No matching operation"
        ~detail:"The harness has not created a managed CPv2 operation for this run yet."
        ~next_tool:"masc_operation_start"
      :: !blockers;
  if operation_ready && not detachment_exists then
    blockers :=
      blocker_item ~code:"missing-detachment" ~severity:"bad"
        ~title:"Operation has no detachment"
        ~detail:"Run the scheduler once so CPv2 can materialize the squad detachment."
        ~next_tool:"masc_dispatch_tick"
      :: !blockers;
  if joined_workers < expected_count then
    blockers :=
      blocker_item ~code:"missing-workers" ~severity:"bad"
        ~title:"Not all workers joined"
        ~detail:(Printf.sprintf "%d of %d workers have live or recorded run evidence." joined_workers expected_count)
        ~next_tool:"masc_join"
      :: !blockers;
  (match runtime_blocker with
  | Some "provider_unreachable" ->
      blockers :=
        blocker_item ~code:"provider_unreachable" ~severity:"bad"
          ~title:"Provider is unreachable"
          ~detail:
            (Option.value runtime_detail
               ~default:"Local provider proxy or llama runtime did not answer the smoke check.")
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "provider_model_mismatch" ->
      blockers :=
        blocker_item ~code:"provider_model_mismatch" ~severity:"bad"
          ~title:"Provider model does not match the requested hot profile"
          ~detail:
            (Printf.sprintf "expected=%s actual=%s"
               (Option.value provider_model_id ~default:"unknown")
               (Option.value actual_model_id ~default:"unknown"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "slot_count_insufficient" ->
      blockers :=
        blocker_item ~code:"slot_count_insufficient" ~severity:"bad"
          ~title:"Runtime exposed fewer slots than the hot profile requires"
          ~detail:
            (Printf.sprintf "expected_slots=%s actual_slots=%s"
               (match expected_slots with Some value -> string_of_int value | None -> "n/a")
               (match actual_slots with Some value -> string_of_int value | None -> "n/a"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "ctx_mismatch" ->
      blockers :=
        blocker_item ~code:"ctx_mismatch" ~severity:"bad"
          ~title:"Runtime context does not match the required hot profile"
          ~detail:
            (Printf.sprintf "expected_ctx=%s actual_ctx=%s"
               (match expected_ctx with Some value -> string_of_int value | None -> "n/a")
               (match actual_ctx with Some value -> string_of_int value | None -> "n/a"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some other ->
      blockers :=
        blocker_item ~code:other ~severity:"bad"
          ~title:"Runtime verification failed"
          ~detail:(Option.value runtime_detail ~default:"The hot runtime contract did not pass.")
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | None -> ());
  if not pass_hot_concurrency && not (Option.is_some runtime_blocker) then
    blockers :=
      blocker_item ~code:"hot-slot-threshold" ~severity:"bad"
        ~title:"Hot concurrency target not reached"
        ~detail:
          (Printf.sprintf "peak hot slots=%d, active now=%d, total slots=%d, ctx=%d"
             peak_hot_slots active_slots_now total_slots ctx_per_slot)
        ~next_tool:"restart llama hot profile"
      :: !blockers;
  if current_task_bound < expected_count then
    blockers :=
      blocker_item ~code:"current-task-gap" ~severity:"warn"
        ~title:"Claimed-without-current_task gap"
        ~detail:"At least one worker is missing run-scoped task ownership or current_task evidence."
        ~next_tool:"masc_plan_set_task"
      :: !blockers;
  if fresh_heartbeats < expected_count then
    blockers :=
      blocker_item ~code:"stale-heartbeat" ~severity:"warn"
        ~title:"Stale worker heartbeat"
        ~detail:"At least one worker heartbeat is stale or missing."
        ~next_tool:"masc_heartbeat"
      :: !blockers;
  if pending_decisions <> [] then
    blockers :=
      blocker_item ~code:"pending-approval" ~severity:"warn"
        ~title:"Pending approval blocks swarm progress"
        ~detail:(Printf.sprintf "%d pending decision(s) for this operation." (List.length pending_decisions))
        ~next_tool:"masc_policy_approve"
      :: !blockers;
  if effective_completed_workers < expected_count then
    blockers :=
      blocker_item ~code:"incomplete-workers" ~severity:"warn"
        ~title:"Not all workers completed"
        ~detail:
          (Printf.sprintf "%d of %d workers reached task completion." effective_completed_workers expected_count)
        ~next_tool:"masc_observe_traces"
      :: !blockers;
  if effective_final_markers_seen < required_final_markers then
    blockers :=
      blocker_item ~code:"missing-final-markers" ~severity:"warn"
        ~title:"Model final markers incomplete"
        ~detail:
          (Printf.sprintf
             "%d of %d model-emitted final markers observed (%d runtime-assisted)."
             effective_final_markers_seen required_final_markers
             effective_runtime_assisted_final_markers_seen)
        ~next_tool:"masc_observe_traces"
      :: !blockers;
  let recommended_next_tool =
    match runtime_blocker with
    | Some _ -> "restart llama hot profile"
    | None ->
        if not operation_ready then
          "masc_operation_start"
        else if not detachment_exists then
          "masc_dispatch_tick"
        else if current_task_bound < expected_count then
          "masc_plan_set_task"
        else if fresh_heartbeats < expected_count then
          "masc_heartbeat"
        else if not pass_hot_concurrency then
          "restart llama hot profile"
        else if pass_end_to_end then
          "masc_operation_finalize"
        else if effective_final_markers_seen < required_final_markers then
          "masc_observe_traces"
        else
          "masc_observe_traces"
  in
  let has_bad_blocker =
    List.exists
      (fun row ->
        U.member "severity" row |> U.to_string_option
        |> (function Some value -> String.equal value "bad" | None -> false))
      !blockers
  in
  let existing_resolution = read_swarm_run_resolution_json config effective_run_id in
  let existing_resolution_status =
    Option.bind existing_resolution swarm_run_resolution_status_of_json
  in
  let partial_run_evidence =
    joined_workers > 0
    || current_task_bound > 0
    || fresh_heartbeats > 0
    || recent_messages <> []
    || relevant_traces <> []
  in
  let operation_paused =
    match selected_operation with
    | Some operation -> operation.status = Paused
    | None -> false
  in
  let continue_available =
    pending_decisions = []
    && (Option.is_some selected_operation || detachment_exists)
  in
  let rerun_available = pending_decisions = [] in
  let abandon_available = true in
  let resolution_recommendation =
    if pending_decisions <> [] then
      None
    else if existing_resolution_status = Some "abandoned" then
      None
    else
      let recommended_kind, reason =
        if
          continue_available
          && (operation_paused || partial_run_evidence || detachment_exists)
          && not (Option.is_some runtime_blocker)
        then
          ( "continue",
            if operation_paused then
              "Matched operation is paused and run-scoped evidence exists. Resume and dispatch before rerunning the harness."
            else if partial_run_evidence then
              "Matched operation or detachment still has worker or trace evidence. Try command-plane recovery before a full rerun."
            else
              "A matching detachment exists for this run. Dispatch recovery is cheaper than a full rerun." )
        else
          ( "rerun",
            if Option.is_some runtime_blocker then
              "Runtime verification failed for this run. Clear the runtime blocker, then rerun the harness for the same run_id."
            else if Option.is_some selected_operation || detachment_exists then
              "The run still maps to managed state, but resumable evidence is too weak. Rerun the harness and rebuild fresh proof."
            else
              "No resumable managed operation or worker evidence remains for this run. Rerun the harness to materialize fresh state." )
      in
      Some
        (`Assoc
          [
            ("run_id", `String effective_run_id);
            ("recommended_kind", `String recommended_kind);
            ("continue_available", `Bool continue_available);
            ("rerun_available", `Bool rerun_available);
            ("abandon_available", `Bool abandon_available);
            ("reason", `String reason);
            ( "evidence",
              `Assoc
                [
                  ("operation_id", option_to_json (fun value -> `String value) (Option.map (fun (operation : operation_record) -> operation.operation_id) selected_operation));
                  ("detachment_id", option_to_json (fun value -> `String value) (Option.map (fun (detachment : detachment_record) -> detachment.detachment_id) matched_detachment));
                  ("joined_workers", `Int joined_workers);
                  ("current_task_bound", `Int current_task_bound);
                  ("fresh_heartbeats", `Int fresh_heartbeats);
                  ("trace_events", `Int (List.length relevant_traces));
                  ("message_events", `Int (List.length recent_messages));
                  ("runtime_blocker", option_to_json (fun value -> `String value) runtime_blocker);
                ] );
            ("provenance", `String "derived");
            ("decision_engine", `String "deterministic_truth_map");
            ("authoritative", `Bool false);
          ])
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("run_id", `String effective_run_id);
      ("room_id", `String room_id);
      ("operation_id", match selected_operation with Some operation -> `String operation.operation_id | None -> `Null);
      ("run_resolution", option_to_json Fun.id existing_resolution);
      ("resolution_recommendation", option_to_json Fun.id resolution_recommendation);
      ("recommended_next_tool", `String recommended_next_tool);
      ( "summary",
        `Assoc
          [
            ("expected_workers", `Int expected_count);
            ("joined_workers", `Int joined_workers);
            ( "live_workers",
              `Int
                (count_true worker_rows (fun row ->
                     U.member "live_presence" row |> U.to_bool_option
                     |> Option.value ~default:false)) );
            ("squad_roster_size", `Int (Option.map (fun (unit : unit_record) -> List.length unit.roster) matched_squad |> Option.value ~default:0));
            ("detachment_roster_size", `Int (Option.map (fun (detachment : detachment_record) -> List.length detachment.roster) matched_detachment |> Option.value ~default:0));
            ("current_task_bound", `Int current_task_bound);
            ("fresh_heartbeats", `Int fresh_heartbeats);
            ("claim_markers_seen", `Int claim_markers_seen);
            ("done_markers_seen", `Int done_markers_seen);
            ("final_markers_seen", `Int effective_final_markers_seen);
            ("runtime_assisted_final_markers", `Int effective_runtime_assisted_final_markers_seen);
            ("completed_workers", `Int effective_completed_workers);
            ("peak_hot_slots", `Int peak_hot_slots);
            ("hot_window_ok", `Bool hot_window_ok);
            ("pass_hot_concurrency", `Bool pass_hot_concurrency);
            ("pass_end_to_end", `Bool pass_end_to_end);
            ("pending_decisions", `Int (List.length pending_decisions));
            ("pass", `Bool (pass_hot_concurrency && pass_end_to_end && not has_bad_blocker));
          ] );
      ( "provider",
        `Assoc
          [
            ("slot_url", match slot_url with Some value -> `String value | None -> `Null);
            ("provider_base_url", match provider_base_url with Some value -> `String value | None -> `Null);
            ("provider_reachable", match provider_reachable with Some value -> `Bool value | None -> `Null);
            ("provider_status_code", match provider_status_code with Some value -> `Int value | None -> `Null);
            ("provider_model_id", match provider_model_id with Some value -> `String value | None -> `Null);
            ("actual_model_id", match actual_model_id with Some value -> `String value | None -> `Null);
            ("expected_slots", match expected_slots with Some value -> `Int value | None -> `Null);
            ("actual_slots", match actual_slots with Some value -> `Int value | None -> `Null);
            ("expected_ctx", match expected_ctx with Some value -> `Int value | None -> `Null);
            ("actual_ctx", match actual_ctx with Some value -> `Int value | None -> `Null);
            ("configured_capacity", match configured_capacity with Some value -> `Int value | None -> `Null);
            ("slot_reachable", match slot_reachable with Some value -> `Bool value | None -> `Null);
            ("slot_status_code", match slot_status_code with Some value -> `Int value | None -> `Null);
            ("runtime_blocker", match runtime_blocker with Some value -> `String value | None -> `Null);
            ("detail", match runtime_detail with Some value -> `String value | None -> `Null);
            ("checked_at", match runtime_checked_at with Some value -> `String value | None -> `Null);
            ("total_slots", `Int total_slots);
            ("ctx_per_slot", `Int ctx_per_slot);
            ("active_slots_now", `Int active_slots_now);
            ("peak_active_slots", `Int peak_hot_slots);
            ("sample_count", `Int sample_count);
            ("last_sample_at", match last_sample_at with Some value -> `String value | None -> `Null);
            ("timeline", `List telemetry_timeline);
          ] );
      ("operation", match selected_operation with Some operation -> operation_to_json operation | None -> `Null);
      ("squad", match matched_squad with Some unit -> unit_to_json unit | None -> `Null);
      ("detachment", match matched_detachment with Some detachment -> detachment_to_json detachment | None -> `Null);
      ("workers", `List worker_rows);
      ("checklist", `List checklist);
      ("blockers", `List (List.rev !blockers));
      ( "recent_messages",
        `List
          (List.map
             (fun (message : Types.message) ->
               `Assoc
                 [
                   ("seq", `Int message.seq);
                   ("from", `String message.from_agent);
                   ("content", `String message.content);
                   ("timestamp", `String message.timestamp);
                 ])
             recent_messages) );
      ("recent_trace_events", `List relevant_traces);
      ( "truth_notes",
        `List
          [
            `String "This endpoint is a read model over room state, CPv2 operations, detachments, decisions, and broadcasts.";
            `String "Workers that already left can still count as joined/task-bound when completed task ownership was recorded; final markers remain extra proof.";
            `String "claim != planning current_task; this surface prefers live room agent state but falls back to run-scoped task ownership.";
            `String "dispatch tick must materialize the detachment before roster and heartbeat checks can pass.";
            `String "Hot concurrency proof comes from llama.cpp /slots telemetry captured by the live harness and stored under .masc/control-plane/swarm-live/<run_id>.";
            `String "Runtime viability comes from runtime-doctor.json plus slot telemetry; hot-swarm pass never silently degrades ctx or slots.";
          ] );
    ]

let unit_guard_json config unit_id =
  let agents, _, units, _ = topology_units config in
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "assigned unit not found: %s" unit_id)
  | Some unit ->
      let live_count =
        unit.roster
        |> List.filter (fun name -> List.mem name (live_agent_names agents))
        |> List.length
      in
      let active_count =
        all_operations config units
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && String.equal operation.assigned_unit_id unit.unit_id)
        |> List.length
      in
      if unit.leader_id = None then
        Error "assigned unit has no leader"
      else if unit.policy.kill_switch then
        Error "assigned unit has kill-switch enabled"
      else if unit.policy.frozen then
        Error "assigned unit is frozen"
      else if live_count = 0 then
        Error "assigned unit has no live agents"
      else if active_count >= unit.budget.active_operation_cap then
        Error
          (Printf.sprintf "assigned unit reached active operation cap (%d)"
             unit.budget.active_operation_cap)
      else
        Ok
          (`Assoc
            [
              ("unit_id", `String unit.unit_id);
              ("live_roster", `Int live_count);
              ("active_operations", `Int active_count);
              ("active_operation_cap", `Int unit.budget.active_operation_cap);
            ])

let replace_operation operations (updated : operation_record) =
  updated
  :: List.filter
       (fun (operation : operation_record) ->
         not (String.equal operation.operation_id updated.operation_id))
       operations

let replace_detachment detachments (updated : detachment_record) =
  updated
  :: List.filter
       (fun (detachment : detachment_record) ->
         not (String.equal detachment.detachment_id updated.detachment_id))
       detachments

let lookup_intent intents intent_id =
  List.find_opt
    (fun (intent : intent_record) -> String.equal intent.intent_id intent_id)
    intents

let replace_intent intents (updated : intent_record) =
  updated
  :: List.filter
       (fun (intent : intent_record) ->
         not (String.equal intent.intent_id updated.intent_id))
       intents

let empty_intent_focus =
  {
    stage = None;
    artifact_scope = [];
    unit_id = None;
    verification_state = None;
  }

let verification_state_of_operation (operation : operation_record) =
  match operation.status, operation.stage with
  | Failed, _ -> Some "failed"
  | Cancelled, _ -> Some "cancelled"
  | Completed, Some "review" -> Some "reviewed"
  | Completed, Some "verify" -> Some "verified"
  | Completed, Some "implement" -> Some "implemented"
  | _, Some "review" -> Some "reviewing"
  | _, Some "verify" -> Some "verifying"
  | _, Some "implement" -> Some "implementing"
  | _ -> None

let intent_state_hint_of_operation_status (operation : operation_record) =
  match operation.status with
  | Planned | Active -> Active_intent
  | Paused -> Suspended_intent
  | Completed -> Completed_intent
  | Cancelled -> Dropped_intent
  | Failed -> Blocked_intent

let focus_of_operation (operation : operation_record) =
  {
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    unit_id = Some operation.assigned_unit_id;
    verification_state = verification_state_of_operation operation;
  }

let touch_intent_from_operation config ~actor (operation : operation_record)
    ~state =
  match operation.intent_id with
  | None -> ()
  | Some intent_id -> (
      match lookup_intent (read_intents config) intent_id with
      | None -> ()
      | Some intent ->
          let linked_operations =
            let operations : operation_record list = read_operations config in
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let aggregated_state =
            if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Failed)
                linked_operations
            then
              Blocked_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Active
                  || linked_operation.status = Planned)
                linked_operations
            then
              Active_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Paused)
                linked_operations
            then
              Suspended_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Completed)
                linked_operations
            then
              Completed_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Cancelled)
                linked_operations
            then
              Dropped_intent
            else
              state
          in
          let updated =
            {
              intent with
              state = aggregated_state;
              current_focus = focus_of_operation operation;
              checkpoint_ref =
                option_first_some operation.checkpoint_ref intent.checkpoint_ref;
              updated_at = Types.now_iso ();
            }
          in
          write_intents config (replace_intent (read_intents config) updated);
          append_event config
            {
              event_id = next_event_id "evt";
              trace_id = next_trace_id ();
              event_type = "intent_synced_from_operation";
              operation_id = Some operation.operation_id;
              unit_id = None;
              actor = Some actor;
              source = "control_plane";
              ts = Types.now_iso ();
              detail =
                `Assoc
                  [
                    ("intent_id", `String updated.intent_id);
                    ("intent_state", `String (string_of_intent_state updated.state));
                  ];
            })

let with_intent config intent_id f =
  let intents = read_intents config in
  match lookup_intent intents intent_id with
  | None -> Error (Printf.sprintf "intent not found: %s" intent_id)
  | Some intent -> f intents intent

let stage_order_for_workload = function
  | "coding_task" -> [ "decompose"; "inspect"; "implement"; "verify"; "review" ]
  | "research_pipeline" -> [ "normalize"; "verify"; "curate"; "rank"; "audit" ]
  | _ -> []

let next_stage_for workload_profile stage =
  let order = stage_order_for_workload workload_profile in
  match stage with
  | None ->
      List.nth_opt order 0
  | Some current -> (
      match List.find_opt (fun stage_name -> String.equal stage_name current) order with
      | None -> None
      | Some stage_name ->
          let rec loop = function
            | [] | [ _ ] -> None
            | head :: next :: _ when String.equal head stage_name -> Some next
            | _ :: rest -> loop rest
          in
          loop order)

let append_cp_event config ~trace_id ~event_type ?operation_id ?unit_id ~actor detail =
  append_event config
    {
      event_id = next_event_id "evt";
      trace_id;
      event_type;
      operation_id;
      unit_id;
      actor = Some actor;
      source = "control_plane";
      ts = Types.now_iso ();
      detail;
    }

let detachment_targets_for_operation units (operation : operation_record) =
  let dedup_by_unit_id rows =
    rows
    |> List.sort_uniq (fun (left : unit_record) (right : unit_record) ->
           String.compare left.unit_id right.unit_id)
  in
  match lookup_unit units operation.assigned_unit_id with
  | Some ({ kind = Company | Platoon; _ } as unit) ->
      let squads = descendant_units_of_kind units unit.unit_id Squad |> dedup_by_unit_id in
      if squads = [] then [ unit ] else squads
  | Some ({ kind = Squad; _ } as unit) -> [ unit ]
  | Some ({ kind = Agent_unit; parent_unit_id = Some parent_id; _ } as unit) -> (
      match lookup_unit units parent_id with
      | Some ({ kind = Squad; _ } as squad) -> [ squad ]
      | _ -> [ unit ])
  | Some unit -> [ unit ]
  | None -> []

let detachment_id_for_operation (operation : operation_record) target_count
    (target_unit : unit_record) =
  if target_count <= 1 then
    "det-" ^ operation.operation_id
  else
    Printf.sprintf "det-%s-%s" operation.operation_id (safe_slug target_unit.unit_id)

let detachment_semantic_equal (left : detachment_record) (right : detachment_record) =
  String.equal left.detachment_id right.detachment_id
  && String.equal left.operation_id right.operation_id
  && String.equal left.assigned_unit_id right.assigned_unit_id
  && left.leader_id = right.leader_id
  && left.roster = right.roster
  && left.session_id = right.session_id
  && left.checkpoint_ref = right.checkpoint_ref
  && left.runtime_kind = right.runtime_kind
  && left.runtime_ref = right.runtime_ref
  && String.equal left.source right.source
  && String.equal left.status right.status
  && left.last_event_at = right.last_event_at
  && left.last_progress_at = right.last_progress_at
  && left.heartbeat_deadline = right.heartbeat_deadline
  && String.equal left.created_at right.created_at

let make_detachment_runtime config (target_unit : unit_record) (operation : operation_record)
    ~target_count ~base =
  let session_id =
    if target_count = 1 then operation.detachment_session_id
    else None
  in
  let session_last_event =
    match session_id with
    | Some value -> (
        match Team_session_store.load_session config value with
        | Some session -> Option.map iso_of_unix session.last_event_at
        | None -> None)
    | None -> None
  in
  let last_progress_at =
    match session_last_event, session_id with
    | Some ts, _ -> Some ts
    | None, Some _ ->
        option_first_some base.last_progress_at (Some operation.updated_at)
    | None, None -> Some operation.updated_at
  in
  let last_event_at =
    match session_last_event, session_id with
    | Some ts, _ -> Some ts
    | None, Some _ -> base.last_event_at
    | None, None -> Some operation.updated_at
  in
  let heartbeat_deadline =
    if operation.status = Active || operation.status = Planned then
      Option.bind last_progress_at (fun base_ts ->
          iso_after_seconds base_ts target_unit.policy.escalation_timeout_sec)
    else
      None
  in
  let draft =
    {
      detachment_id = detachment_id_for_operation operation target_count target_unit;
      operation_id = operation.operation_id;
      assigned_unit_id = target_unit.unit_id;
      leader_id = option_first_some target_unit.leader_id base.leader_id;
      roster = if target_unit.roster <> [] then target_unit.roster else base.roster;
      session_id;
      checkpoint_ref = option_first_some operation.checkpoint_ref base.checkpoint_ref;
      runtime_kind =
        (if target_count = 1 && session_id <> None then Some "team_session"
         else Some "managed");
      runtime_ref =
        (if target_count = 1 then option_first_some session_id (Some target_unit.unit_id)
         else Some target_unit.unit_id);
      source = "managed";
      status = string_of_operation_status operation.status;
      last_event_at;
      last_progress_at;
      heartbeat_deadline;
      created_at = base.created_at;
      updated_at = Types.now_iso ();
    }
  in
  if detachment_semantic_equal draft base then
    { draft with updated_at = base.updated_at }
  else
    draft

let default_detachment_for_operation config units (operation : operation_record) =
  let fallback_target =
    match detachment_targets_for_operation units operation with
    | target :: _ -> target
    | [] ->
        {
          unit_id = operation.assigned_unit_id;
          label = operation.assigned_unit_id;
          kind = Squad;
          parent_unit_id = None;
          leader_id = None;
          roster = [];
          capability_profile = [];
          policy = default_policy Squad;
          budget = default_budget Squad;
          source = "managed";
          created_at = operation.created_at;
          updated_at = operation.updated_at;
        }
  in
  make_detachment_runtime config fallback_target operation ~target_count:1
    ~base:
      {
        detachment_id = "det-" ^ operation.operation_id;
        operation_id = operation.operation_id;
        assigned_unit_id = fallback_target.unit_id;
        leader_id = fallback_target.leader_id;
        roster = fallback_target.roster;
        session_id = operation.detachment_session_id;
        checkpoint_ref = operation.checkpoint_ref;
        runtime_kind = None;
        runtime_ref = None;
        source = "managed";
        status = string_of_operation_status operation.status;
        last_event_at = None;
        last_progress_at = Some operation.updated_at;
        heartbeat_deadline = None;
        created_at = operation.created_at;
        updated_at = operation.updated_at;
      }

let search_upstreams operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.map (fun upstream_id ->
         match
           List.find_opt
             (fun (candidate : operation_record) ->
               String.equal candidate.operation_id upstream_id)
             operations
         with
         | Some upstream ->
             {
               Cp_search_fabric.operation_id = upstream.operation_id;
               status = string_of_operation_status upstream.status;
               checkpoint_ref = upstream.checkpoint_ref;
             }
         | None ->
             {
               Cp_search_fabric.operation_id = upstream_id;
               status = "missing";
               checkpoint_ref = None;
             })

let operation_readiness operations operation =
  match operation_search_strategy operation with
  | Cp_search_fabric.Legacy -> Cp_search_fabric.Ready
  | Cp_search_fabric.Best_first_v1 ->
      Cp_search_fabric.readiness_for_operation
        ~upstreams:(search_upstreams operations operation)

let sync_managed_detachments config units (operation : operation_record) =
  let operations = read_operations config in
  let detachments = read_detachments config in
  let existing_for_operation =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           String.equal detachment.operation_id operation.operation_id
           && String.equal detachment.source "managed")
  in
  let readiness = operation_readiness operations operation in
  let targets =
    match operation_search_strategy operation, readiness with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _ -> []
    | _ -> (
        match detachment_targets_for_operation units operation with
        | [] -> []
        | rows -> rows)
  in
  let target_count = max 1 (List.length targets) in
  let updated_rows =
    match operation_search_strategy operation, readiness, targets with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _, _ -> []
    | _, _, [] ->
        [ default_detachment_for_operation config units operation ]
    | _, _, rows ->
        rows
        |> List.map (fun (target_unit : unit_record) ->
               let detachment_id =
                 detachment_id_for_operation operation target_count target_unit
               in
               let base =
                 existing_for_operation
                 |> List.find_opt (fun (detachment : detachment_record) ->
                        String.equal detachment.detachment_id detachment_id)
                 |> Option.value
                      ~default:
                        {
                          detachment_id;
                          operation_id = operation.operation_id;
                          assigned_unit_id = target_unit.unit_id;
                          leader_id = target_unit.leader_id;
                          roster = target_unit.roster;
                          session_id = operation.detachment_session_id;
                          checkpoint_ref = operation.checkpoint_ref;
                          runtime_kind = None;
                          runtime_ref = None;
                          source = "managed";
                          status = string_of_operation_status operation.status;
                          last_event_at = None;
                          last_progress_at = Some operation.updated_at;
                          heartbeat_deadline = None;
                          created_at = operation.created_at;
                          updated_at = operation.updated_at;
                        }
               in
               make_detachment_runtime config target_unit operation ~target_count ~base)
  in
  let remaining =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           not
             (String.equal detachment.operation_id operation.operation_id
              && String.equal detachment.source "managed"))
  in
  write_detachments config (updated_rows @ remaining);
  updated_rows

let sync_managed_detachment config units (operation : operation_record) =
  match sync_managed_detachments config units operation with
  | row :: _ -> row
  | [] -> default_detachment_for_operation config units operation

let with_operation config operation_id f =
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current -> f operations current

let rec nearest_ancestor units unit_id predicate =
  match lookup_unit units unit_id with
  | Some unit when predicate unit -> Some unit
  | Some unit -> (
      match unit.parent_unit_id with
      | Some parent_id -> nearest_ancestor units parent_id predicate
      | None -> None)
  | None -> None

let platoon_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Platoon)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let company_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Company)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let same_platoon units left right =
  match platoon_ancestor_id units left, platoon_ancestor_id units right with
  | Some a, Some b -> String.equal a b
  | _ -> false

let list_children_of_kind units parent_id kind =
  units
  |> List.filter (fun (unit : unit_record) ->
         unit.kind = kind
         &&
         match unit.parent_unit_id with
         | Some value -> String.equal value parent_id
         | None -> false)

let candidate_units_for_operation units operations current_unit_id =
  let score_unit (unit : unit_record) =
    let active_count =
      operations
      |> List.filter (fun (operation : operation_record) ->
             active_operation_status operation.status
             && String.equal operation.assigned_unit_id unit.unit_id)
      |> List.length
    in
    let capacity_left = max 0 (unit.budget.active_operation_cap - active_count) in
    let same_parent =
      match current_unit_id with
      | Some source -> same_platoon units source unit.unit_id
      | None -> false
    in
    (if same_parent then 1000 else 0) + (capacity_left * 10) + List.length unit.roster
  in
  units
  |> List.filter (fun (unit : unit_record) ->
         (unit.kind = Squad || unit.kind = Platoon)
         && not unit.policy.kill_switch && not unit.policy.frozen)
  |> List.sort (fun a b -> compare (score_unit b, b.label) (score_unit a, a.label))

let decision_requires_approval units source_unit_id target_unit_id =
  match lookup_unit units target_unit_id with
  | None -> true
  | Some target ->
      if target.policy.approval_class = "strict" then
        true
      else
        match source_unit_id with
        | None -> false
        | Some source when String.equal source target_unit_id -> false
        | Some source -> not (same_platoon units source target_unit_id)

let search_operation_descriptor (operation : operation_record) =
  {
    Cp_search_fabric.operation_id = Some operation.operation_id;
    objective = operation.objective;
    assigned_unit_id = Some operation.assigned_unit_id;
    workload_profile = operation_workload_profile operation;
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    depends_on_operation_ids = operation.depends_on_operation_ids;
    created_at = operation.created_at;
  }

let operation_active_count operations unit_id =
  operations
  |> List.filter (fun (operation : operation_record) ->
         active_operation_status operation.status
         && String.equal operation.assigned_unit_id unit_id)
  |> List.length

let search_candidates_for_operation config units operations
    (operation : operation_record) =
  let current_unit_id = Some operation.assigned_unit_id in
  candidate_units_for_operation units operations current_unit_id
  |> List.filter_map (fun (unit : unit_record) ->
         match unit_guard_json config unit.unit_id with
         | Error _ -> None
         | Ok _ ->
             if decision_requires_approval units current_unit_id unit.unit_id then
               None
             else
               Some
                 {
                   Cp_search_fabric.unit_id = unit.unit_id;
                   label = unit.label;
                   capability_profile = unit.capability_profile;
                   active_operation_cap = unit.budget.active_operation_cap;
                   active_operations = operation_active_count operations unit.unit_id;
                   current_assignment = String.equal unit.unit_id operation.assigned_unit_id;
                 })

let candidate_matches_scope candidate scope =
  let haystack =
    String.concat " "
      [ candidate.Cp_search_fabric.unit_id; candidate.label; candidate.routing_reason ]
    |> String.lowercase_ascii
  in
  let terms =
    scope
    |> List.concat_map (fun raw ->
           raw
           |> String.split_on_char '/'
           |> List.concat_map (String.split_on_char '.'))
    |> List.map String.trim
    |> List.filter (fun value -> String.length value >= 3)
  in
  List.exists
    (fun term ->
      let term = String.lowercase_ascii term in
      let len_term = String.length term in
      let len_haystack = String.length haystack in
      let rec loop idx =
        if idx > len_haystack - len_term then false
        else if String.sub haystack idx len_term = term then true
        else loop (idx + 1)
      in
      len_haystack >= len_term && loop 0)
    terms

let apply_intent_forecast_bias config (operations : operation_record list)
    (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  match operation.intent_id with
  | None -> candidates
  | Some intent_id -> (
      match lookup_intent (read_intents config) intent_id with
      | None -> candidates
      | Some intent ->
          let unresolved_for_operation (current_operation : operation_record) =
            current_operation.depends_on_operation_ids
            |> List.filter_map (fun dep_id ->
                   match operation_by_id operations dep_id with
                   | Some upstream when upstream.status = Completed -> None
                   | Some upstream when Option.is_some upstream.checkpoint_ref -> None
                   | Some upstream -> Some upstream.operation_id
                   | None -> Some dep_id)
          in
          let linked : operation_record list =
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let latest_operation = List.nth_opt linked 0 in
          let recommended_stage =
            match latest_operation with
            | Some latest when latest.status = Completed ->
                next_stage_for intent.workload_profile latest.stage
            | Some latest -> latest.stage
            | None ->
                option_first_some (next_stage_for intent.workload_profile intent.current_focus.stage)
                  intent.current_focus.stage
          in
          let recommended_scope =
            match latest_operation with
            | Some latest when latest.artifact_scope <> [] -> latest.artifact_scope
            | _ ->
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors
          in
          let verification_ready =
            match normalize_stage operation.stage with
            | Some ("verify" | "review") -> unresolved_for_operation operation = []
            | _ -> true
          in
          candidates
          |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
                 let intent_successor =
                   (if recommended_stage = operation.stage then 10.0 else 0.0)
                   +. if candidate_matches_scope candidate recommended_scope then 5.0 else 0.0
                 in
                 let verification_readiness =
                   match normalize_stage operation.stage with
                   | Some "verify" ->
                       if verification_ready then 10.0 else 0.0
                   | Some "review" ->
                       if verification_ready then 10.0 else 0.0
                   | _ -> 0.0
                 in
                 let breakdown =
                   {
                     candidate.breakdown with
                     intent_successor;
                     verification_readiness;
                     total =
                       candidate.breakdown.total
                       +. intent_successor +. verification_readiness;
                   }
                 in
                 {
                   candidate with
                   breakdown;
                   routing_reason =
                     Printf.sprintf "%s intent=%.1f verify=%.1f"
                       candidate.routing_reason intent_successor
                       verification_readiness;
                 })
          |> List.sort (fun left right ->
                 let left : Cp_search_fabric.scored_candidate = left in
                 let right : Cp_search_fabric.scored_candidate = right in
                 compare
                   (right.breakdown.total, right.breakdown.capability_match, right.label)
                   (left.breakdown.total, left.breakdown.capability_match, left.label)))

let operation_search_candidates config units operations
    (operation : operation_record) =
  let stats = read_search_stats config in
  Cp_search_fabric.score_candidates ~store:stats
    ~operation:(search_operation_descriptor operation)
    ~candidates:(search_candidates_for_operation config units operations operation)
  |> apply_intent_forecast_bias config operations operation

let take_list n xs =
  let rec loop acc remaining count =
    match remaining, count with
    | _, count when count <= 0 -> List.rev acc
    | [], _ -> List.rev acc
    | item :: rest, _ -> loop (item :: acc) rest (count - 1)
  in
  loop [] xs n

let speculative_candidates_for_operation (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  List.map
    (fun (candidate : Cp_search_fabric.scored_candidate) ->
      {
        Speculative_engine.label = candidate.unit_id;
        prompt =
          Printf.sprintf
            "Objective: %s\nWorkload: %s\nStage: %s\nArtifact scope: %s\nCandidate unit: %s\nSearch score: %.1f\nRouting reason: %s\n\nDecide whether this is the best execution target. Keep the answer concise."
            operation.objective
            (operation_workload_profile operation)
            (operation_stage_key operation)
            (if operation.artifact_scope = [] then "(unspecified)"
             else String.concat ", " operation.artifact_scope)
            candidate.unit_id
            candidate.breakdown.total
            candidate.routing_reason;
        metadata =
          `Assoc
            [
              ("unit_id", `String candidate.unit_id);
              ("score", `Float candidate.breakdown.total);
              ("routing_reason", `String candidate.routing_reason);
            ];
      })
    candidates

let speculative_pick_candidate config (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  if
    not (room_speculation_enabled config)
    || operation_search_strategy operation <> Cp_search_fabric.Best_first_v1
    ||
    not
      (String.equal (operation_workload_profile operation) "coding_task"
       &&
       match normalize_stage operation.stage with
       | Some ("inspect" | "review") -> true
       | _ -> false)
    || List.length candidates < 2
  then
    None
  else
    let budget = min (room_speculation_budget config) (List.length candidates) in
    let candidates = take_list budget candidates in
    match
      Speculative_engine.speculate Tool_risc.global_spec_engine
        ~goal:(Printf.sprintf "route-%s" operation.operation_id)
        ~original_query:operation.objective
        ~candidates:(speculative_candidates_for_operation operation candidates)
    with
    | Ok outcome ->
        List.find_opt
          (fun (candidate : Cp_search_fabric.scored_candidate) ->
            String.equal candidate.unit_id outcome.candidate_label)
          candidates
    | Error _ -> None

let operation_search_json config units operations (operation : operation_record) =
  let readiness = operation_readiness operations operation in
  let candidates =
    match operation_search_strategy operation with
    | Cp_search_fabric.Legacy -> []
    | Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates config units operations operation
  in
  let selected_unit_id =
    match candidates with
    | best :: _ -> Some best.Cp_search_fabric.unit_id
    | [] -> Some operation.assigned_unit_id
  in
  let base_json =
    Cp_search_fabric.summary_json
      ~strategy:(operation_search_strategy operation)
      ~readiness ~candidates ~selected_unit_id
  in
  match base_json with
  | `Assoc fields ->
      `Assoc
        ( ("speculation",
           `Assoc
             [
               ("enabled", `Bool (room_speculation_enabled config));
               ( "stage_allowed",
                 `Bool
                   (String.equal (operation_workload_profile operation) "coding_task"
                    &&
                    match normalize_stage operation.stage with
                    | Some ("inspect" | "review") -> true
                    | _ -> false) );
               ("budget", `Int (room_speculation_budget config));
             ] )
        :: fields )
  | other -> other

let update_search_stats_for_operation config operation ~outcome =
  let stage = operation_stage_key operation in
  let workload_profile = operation_workload_profile operation in
  let current = read_search_stats config in
  let updated =
    match outcome with
    | `Success ->
        Cp_search_fabric.record_success current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
    | `Failure ->
        Cp_search_fabric.record_failure current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
  in
  write_search_stats config updated

let operation_card_json config units operations (operation : operation_record) =
  let unit_label =
    lookup_unit units operation.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:operation.assigned_unit_id
  in
  let intent_json =
    match operation.intent_id with
    | Some intent_id -> (
        match lookup_intent (read_intents config) intent_id with
        | Some intent -> intent_to_json intent
        | None ->
            `Assoc
              [
                ("status", `String "error");
                ("message", `String (Printf.sprintf "intent not found: %s" intent_id));
              ])
    | None -> `Null
  in
  `Assoc
    [
      ("operation", operation_to_json operation);
      ("assigned_unit_label", `String unit_label);
      ("intent", intent_json);
      ("search", operation_search_json config units operations operation);
    ]

let list_operations_json_from_state ?operation_id (state : snapshot_state) =
  let units = state.units in
  let operations =
    state.operations
    |> List.filter (fun (operation : operation_record) ->
           match operation_id with
           | None -> true
           | Some value ->
               String.equal operation.operation_id value
               || String.equal operation.trace_id value)
  in
  let managed_count =
    List.length
      (List.filter (fun (operation : operation_record) -> operation.source = "managed") operations)
  in
  let projected_count = List.length operations - managed_count in
  let microarch =
    operations_summary_json_from_state { state with operations }
    |> U.member "microarch"
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length operations));
            ( "active",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Active)
                      operations)) );
            ( "paused",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Paused)
                      operations)) );
            ("managed", `Int managed_count);
            ("projected", `Int projected_count);
          ] );
      ("microarch", microarch);
      ( "operations",
        `List
          (List.map
             (operation_card_json state.config units state.operations)
             operations) );
    ]

let list_operations_json ?operation_id config =
  list_operations_json_from_state ?operation_id (build_snapshot_state config)

let linked_operations_for_intent config intent_id =
  let operations : operation_record list = read_operations config in
  let filtered =
    List.filter
      (fun (operation : operation_record) ->
        match operation.intent_id with
        | Some current -> String.equal current intent_id
        | None -> false)
      operations
  in
  List.sort
    (fun (left : operation_record) (right : operation_record) ->
      String.compare right.updated_at left.updated_at)
    filtered

let intent_focus_json focus = intent_focus_to_json focus

let unresolved_dependencies operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.filter_map (fun dep_id ->
         match operation_by_id operations dep_id with
         | Some upstream when upstream.status = Completed -> None
         | Some upstream when Option.is_some upstream.checkpoint_ref -> None
         | Some upstream -> Some upstream.operation_id
         | None -> Some dep_id)

let intent_forecast_json config intent_id ?(limit = 3) () =
  with_intent config intent_id (fun _ intent ->
      let _, _, units, _ = topology_units config in
      let all_operations = all_operations config units in
      let intent_operations =
        all_operations
        |> List.filter (fun (operation : operation_record) ->
               match operation.intent_id with
               | Some current -> String.equal current intent_id
               | None -> false)
        |> List.sort (fun (left : operation_record) (right : operation_record) ->
               String.compare right.updated_at left.updated_at)
      in
      let latest_operation = List.nth_opt intent_operations 0 in
      let base_focus =
        match latest_operation with
        | Some operation -> focus_of_operation operation
        | None ->
            {
              intent.current_focus with
              artifact_scope =
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors;
            }
      in
      let risk_flags =
        let flags = ref [] in
        (match latest_operation with
        | None -> flags := "no_linked_operations" :: !flags
        | Some operation ->
            if operation.status = Failed then
              flags := "failed_operation_present" :: !flags;
            if
              String.equal intent.workload_profile "coding_task"
              && base_focus.artifact_scope = []
              &&
              match base_focus.stage with
              | Some "decompose" | None -> false
              | _ -> true
            then
              flags := "missing_artifact_scope" :: !flags;
            if
              match normalize_stage operation.stage with
              | Some ("verify" | "review") ->
                  unresolved_dependencies all_operations operation <> []
              | _ -> false
            then
              flags := "verification_gap" :: !flags);
        List.rev !flags
      in
      let blocked_by =
        match latest_operation with
        | Some operation -> unresolved_dependencies all_operations operation
        | None -> []
      in
      let candidate_focuses =
        let artifact_scope =
          if base_focus.artifact_scope <> [] then base_focus.artifact_scope
          else intent.artifact_priors
        in
        let make_candidate ~stage ~score ~reason =
          let verification_state =
            match stage with
            | Some "verify" -> Some "needs_implement_checkpoint"
            | Some "review" -> Some "needs_verify_checkpoint"
            | Some "implement" -> Some "code_change_pending"
            | _ -> base_focus.verification_state
          in
          `Assoc
            [
              ("stage", match stage with Some value -> `String value | None -> `Null);
              ("artifact_scope", json_list_of_strings artifact_scope);
              ("unit_id", match base_focus.unit_id with Some value -> `String value | None -> `Null);
              ( "verification_state",
                match verification_state with Some value -> `String value | None -> `Null );
              ("successor_score", `Float score);
              ("reason", `String reason);
            ]
        in
        match latest_operation with
        | None ->
            [ make_candidate ~stage:(next_stage_for intent.workload_profile None)
                ~score:0.9 ~reason:"bootstrap from adopted intent" ]
        | Some operation -> (
            let next_stage = next_stage_for intent.workload_profile operation.stage in
            match operation.status with
            | Completed ->
                [
                  make_candidate ~stage:next_stage ~score:0.92
                    ~reason:"advance to successor stage after completed operation";
                  make_candidate ~stage:operation.stage ~score:0.35
                    ~reason:"keep recent focus warm for follow-up";
                ]
            | Active | Planned | Paused ->
                [
                  make_candidate ~stage:operation.stage ~score:0.78
                    ~reason:"continue active focus";
                  make_candidate ~stage:next_stage ~score:0.58
                    ~reason:"prepare successor stage in parallel";
                ]
            | Failed | Cancelled ->
                [
                  make_candidate ~stage:operation.stage ~score:0.25
                    ~reason:"recover failed focus before advancing";
                ])
      in
      let candidate_focuses =
        candidate_focuses
        |> List.filteri (fun idx _ -> idx < limit)
      in
      let recommended_focus =
        match candidate_focuses with
        | (`Assoc _ as focus) :: _ -> focus
        | _ -> intent_focus_json base_focus
      in
      Ok
        (`Assoc
          [
            ("intent", intent_to_json intent);
            ("current_focus", intent_focus_json base_focus);
            ("candidate_next_states", `List candidate_focuses);
            ("risk_flags", json_list_of_strings risk_flags);
            ("blocked_by", json_list_of_strings blocked_by);
            ("recommended_focus", recommended_focus);
          ]))

let list_intents_json ?intent_id config =
  let intents = read_intents config in
  let rows =
    intents
    |> List.filter (fun (intent : intent_record) ->
           match intent_id with
           | Some value -> String.equal intent.intent_id value
           | None -> true)
  in
  let state_count state =
    rows
    |> List.filter (fun (intent : intent_record) -> intent.state = state)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length rows));
            ("active", `Int (state_count Active_intent));
            ("blocked", `Int (state_count Blocked_intent));
            ("handoff_ready", `Int (state_count Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json rows));
    ]

let create_intent_json config ~(actor : string) json =
  let title =
    match get_string_opt json "title" with
    | Some value -> value
    | None -> invalid_arg "title is required"
  in
  let workload_profile_raw =
    get_string_default json "workload_profile" "coding_task"
  in
  let* workload_profile = validate_workload_profile workload_profile_raw in
  let current_focus =
    match U.member "current_focus" json with
    | `Assoc _ as value -> intent_focus_of_json value
    | _ -> empty_intent_focus
  in
  let intent =
    {
      intent_id = next_intent_id ();
      title;
      owner = get_string_default json "owner" actor;
      workload_profile;
      success_metric =
        (match U.member "success_metric" json with
        | `Null -> None
        | value -> Some value);
      invariants = get_string_list json "invariants";
      artifact_priors = get_string_list json "artifact_priors";
      state =
        (match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None -> Adopted)
        | None -> Adopted);
      current_focus;
      checkpoint_ref = get_string_opt json "checkpoint_ref";
      source = "managed";
      created_at = Types.now_iso ();
      updated_at = Types.now_iso ();
    }
  in
  let intents = read_intents config in
  write_intents config (intent :: intents);
  append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_created"
    ~actor (`Assoc [ ("intent_id", `String intent.intent_id) ]);
  Ok intent

let update_intent_json config ~(actor : string) json =
  let intent_id =
    match get_string_opt json "intent_id" with
    | Some value -> value
    | None -> invalid_arg "intent_id is required"
  in
  with_intent config intent_id (fun intents intent ->
      let workload_profile =
        match get_string_opt json "workload_profile" with
        | Some value -> validate_workload_profile value
        | None -> Ok intent.workload_profile
      in
      let* workload_profile = workload_profile in
      let current_focus =
        match U.member "current_focus" json with
        | `Assoc _ as value -> intent_focus_of_json value
        | _ -> intent.current_focus
      in
      let state =
        match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None ->
                invalid_arg
                  (Printf.sprintf "unsupported intent state: %s" value))
        | None -> intent.state
      in
      let updated =
        {
          intent with
          title = get_string_default json "title" intent.title;
          owner = get_string_default json "owner" intent.owner;
          workload_profile;
          success_metric =
            (match U.member "success_metric" json with
            | `Null -> intent.success_metric
            | value -> Some value);
          invariants =
            (match U.member "invariants" json with
            | `List _ -> get_string_list json "invariants"
            | _ -> intent.invariants);
          artifact_priors =
            (match U.member "artifact_priors" json with
            | `List _ -> get_string_list json "artifact_priors"
            | _ -> intent.artifact_priors);
          state;
          current_focus;
          checkpoint_ref =
            option_first_some (get_string_opt json "checkpoint_ref")
              intent.checkpoint_ref;
          updated_at = Types.now_iso ();
        }
      in
      write_intents config (replace_intent intents updated);
      append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_updated"
        ~actor (`Assoc [ ("intent_id", `String updated.intent_id) ]);
      Ok updated)

let snapshot_json config =
  let state = build_snapshot_state config in
  let topology = topology_json_from_state state in
  let intents = intents_summary_json_from_state state in
  let operations = list_operations_json_from_state state in
  let detachments = list_detachments_json_from_state state in
  let alerts = list_alerts_json_from_state config state in
  let decisions = list_policy_decisions_json_from_state state in
  let capacity = capacity_json_from_state state in
  let traces = list_traces_json config ~limit:10 () in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology);
      ("intents", intents);
      ("operations", operations);
      ("detachments", detachments);
      ("alerts", alerts);
      ("decisions", decisions);
      ("capacity", capacity);
      ("traces", traces);
    ]

let operation_status_json config ?operation_id () =
  list_operations_json ?operation_id config

let company_scope_id_for units source_unit_id target_unit_id =
  option_first_some
    (Option.bind target_unit_id (fun unit_id -> company_ancestor_id units unit_id))
    (Option.bind source_unit_id (fun unit_id -> company_ancestor_id units unit_id))
  |> Option.value ~default:"company-runtime"

let find_pending_decision config ~requested_action ?operation_id ?target_unit_id () =
  all_policy_decisions config
  |> List.find_opt (fun (decision : policy_decision_record) ->
         String.equal decision.status "pending"
         && String.equal decision.requested_action requested_action
         &&
         match operation_id, decision.operation_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false
         &&
         match target_unit_id, decision.target_unit_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false)

let create_policy_decision config ~(actor : string) ~requested_action ~scope_type
    ~scope_id ?operation_id ?target_unit_id ~reason ?(source = "managed") detail =
  let decision =
    {
      decision_id = next_event_id "dec";
      trace_id = next_trace_id ();
      requested_action;
      scope_type;
      scope_id;
      operation_id;
      target_unit_id;
      requested_by = actor;
      status = "pending";
      reason;
      source;
      detail;
      created_at = Types.now_iso ();
      decided_at = None;
      expires_at =
        (let ttl = Env_config.Decision.ttl_seconds in
         let t = Unix.gettimeofday () +. ttl in
         let tm = Unix.gmtime t in
         Some (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
           (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
           tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec));
    }
  in
  let decisions = read_policy_decisions config in
  write_policy_decisions config (decision :: decisions);
  append_cp_event config ~trace_id:decision.trace_id ~event_type:"policy_decision_requested"
    ?operation_id ?unit_id:target_unit_id ~actor
    (`Assoc
      [
        ("decision_id", `String decision.decision_id);
        ("requested_action", `String requested_action);
        ("scope_type", `String scope_type);
        ("scope_id", `String scope_id);
      ]);
  decision

(** Expire pending decisions that have passed their TTL.
    Returns count of expired decisions. *)
let check_expired_decisions config =
  let now = Types.now_iso () in
  let decisions = read_policy_decisions config in
  let expired_count = ref 0 in
  let updated = List.map (fun (d : policy_decision_record) ->
    match d.status, d.expires_at with
    | "pending", Some exp when exp < now ->
        incr expired_count;
        { d with status = "expired"; decided_at = Some now }
    | _ -> d
  ) decisions in
  if !expired_count > 0 then
    write_policy_decisions config updated;
  !expired_count

(** BUG-019: Auto-fail blocked intents past timeout (default 3600s).
    Returns count of failed intents. *)
let check_blocked_intents config =
  let timeout_sec = Env_config.Decision.ttl_seconds in
  let now = Types.now_iso () in
  let now_unix = Unix.gettimeofday () in
  let intents = read_intents config in
  let failed_count = ref 0 in
  let updated = List.map (fun (intent : intent_record) ->
    match intent.state with
    | Blocked_intent ->
        let created_unix = Types.parse_iso8601 intent.created_at in
        if now_unix -. created_unix > timeout_sec then begin
          incr failed_count;
          { intent with state = Dropped_intent; updated_at = now }
        end else
          intent
    | _ -> intent
  ) intents in
  if !failed_count > 0 then
    write_intents config updated;
  !failed_count

let apply_operation_assignment config ~(actor : string) (operation : operation_record)
    ~target_unit_id ~note ~event_type =
  match unit_guard_json config target_unit_id with
  | Error message -> Error message
  | Ok _ ->
      let updated =
        {
          operation with
          assigned_unit_id = target_unit_id;
          note =
            (match note, operation.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      touch_intent_from_operation config ~actor updated ~state:Active_intent;
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc
          [
            ("from_unit_id", `String operation.assigned_unit_id);
            ("to_unit_id", `String target_unit_id);
          ]);
      Ok updated

let update_operation_status config ~(actor : string) ~operation_id ~status ~note ~event_type =
  with_operation config operation_id (fun operations current ->
      let next_chain_status =
        match status with
        | Planned -> Some "pending"
        | Active -> Some "running"
        | Paused -> Some "paused"
        | Cancelled -> Some "cancelled"
        | Completed -> Some "completed"
        | Failed -> Some "failed"
      in
      let updated =
        {
          current with
          status;
          chain =
            (match current.chain, next_chain_status with
            | Some chain, Some chain_status ->
                Some { chain with status = chain_status }
            | None, Some _ -> None
            | existing, None -> existing);
          note =
            (match note, current.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      let intent_state =
        match status with
        | Planned | Active -> Active_intent
        | Paused -> Suspended_intent
        | Completed -> Completed_intent
        | Cancelled -> Dropped_intent
        | Failed -> Blocked_intent
      in
      touch_intent_from_operation config ~actor updated ~state:intent_state;
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("status", `String (string_of_operation_status status)) ]);
      Ok updated)

let update_operation config ~(actor : string) ~operation_id ?event_type ?detail f =
  with_operation config operation_id (fun operations current ->
      let updated : operation_record =
        f current |> fun (operation : operation_record) -> { operation with updated_at = Types.now_iso () }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      (match event_type with
      | Some current_event_type ->
          append_cp_event config ~trace_id:updated.trace_id ~event_type:current_event_type
            ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id
            ~actor
            (Option.value ~default:(`Assoc []) detail)
      | None -> ());
      Ok updated)

let update_unit config ~(actor : string) ~unit_id f ~event_type detail =
  let units = read_units config in
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "unit not found: %s" unit_id)
  | Some current ->
      let updated : unit_record = f current in
      let validation_pool =
        List.filter
          (fun (unit : unit_record) -> not (String.equal unit.unit_id updated.unit_id))
          (effective_units_for_validation config units)
      in
      (match validate_unit_shape validation_pool updated with
      | Error message -> Error message
      | Ok () ->
          write_units config (updated :: validation_pool);
          append_cp_event config ~trace_id:(next_trace_id ()) ~event_type
            ~unit_id:updated.unit_id ~actor detail;
          Ok updated)

let start_operation config ~(actor : string) json =
  let validate_coding_dependency_requirement ~stage ~depends_on_operation_ids =
    let expected_stage =
      match stage with
      | "verify" -> Some "implement"
      | "review" -> Some "verify"
      | _ -> None
    in
    match expected_stage with
    | None -> Ok ()
    | Some expected_stage ->
        if depends_on_operation_ids = [] then
          Error
            (Printf.sprintf
               "coding_task %s stage requires at least one %s dependency"
               stage expected_stage)
        else
          let operations = read_operations config in
          if
            List.exists
              (fun dep_id ->
                match operation_by_id operations dep_id with
                | Some dependency ->
                    String.equal (operation_workload_profile dependency) "coding_task"
                    && normalize_stage dependency.stage = Some expected_stage
                | None -> false)
              depends_on_operation_ids
          then
            Ok ()
          else
            Error
              (Printf.sprintf
                 "coding_task %s stage requires a coding_task %s dependency"
                 stage expected_stage)
  in
  let assigned_unit_id =
    match get_string_opt json "assigned_unit_id" with
    | Some value -> value
    | None -> invalid_arg "assigned_unit_id is required"
  in
  let objective =
    match get_string_opt json "objective" with
    | Some value -> value
    | None -> invalid_arg "objective is required"
  in
  match unit_guard_json config assigned_unit_id with
  | Error message -> Error message
  | Ok _ ->
      let workload_template =
        match get_string_opt json "workload_template" with
        | Some value ->
            let* validated = validate_workload_template value in
            Ok (Some validated)
        | None -> Ok None
      in
      let* workload_template = workload_template in
      let inferred_workload_profile, inferred_stage =
        match workload_template with
        | Some template -> (
            match workload_template_defaults template with
            | Some defaults -> defaults
            | None -> ("coding_task", None))
        | None -> ("coding_task", None)
      in
      let explicit_workload_profile = get_string_opt json "workload_profile" in
      let* () =
        match workload_template, explicit_workload_profile with
        | Some template, Some explicit_profile -> (
            let expected_profile, _ =
              match workload_template_defaults template with
              | Some defaults -> defaults
              | None -> ("coding_task", None)
            in
            let* normalized_explicit = validate_workload_profile explicit_profile in
            if String.equal normalized_explicit expected_profile then
              Ok ()
            else
              Error
                (Printf.sprintf
                   "workload_template %s requires workload_profile=%s"
                   template expected_profile))
        | _ -> Ok ()
      in
      let workload_profile_raw =
        match explicit_workload_profile with
        | Some value -> value
        | None -> inferred_workload_profile
      in
      let requested_stage =
        match get_string_opt json "stage" with
        | Some value -> Some value
        | None -> inferred_stage
      in
      let search_strategy_raw =
        get_string_default json "search_strategy" (room_search_strategy_default config)
      in
      let depends_on_operation_ids = get_string_list json "depends_on_operation_ids" in
      let requested_intent_id = get_string_opt json "intent_id" in
      let raw_artifact_scope = get_string_list json "artifact_scope" in
      let* workload_profile = validate_workload_profile workload_profile_raw in
      let* stage =
        validate_stage_for_workload ~workload_profile requested_stage
      in
      let* search_strategy = validate_search_strategy search_strategy_raw in
      let* intent_binding =
        match requested_intent_id with
        | None -> Ok None
        | Some intent_id ->
            with_intent config intent_id (fun _ intent ->
                if not (String.equal intent.workload_profile workload_profile) then
                  Error
                    (Printf.sprintf
                       "intent workload_profile mismatch: intent=%s operation=%s"
                       intent.workload_profile workload_profile)
                else
                  Ok (Some intent))
      in
      let artifact_scope =
        match intent_binding with
        | Some intent when raw_artifact_scope = [] -> intent.artifact_priors
        | _ -> raw_artifact_scope
      in
      let* () =
        match workload_profile, stage with
        | "coding_task", Some ("verify" | "review" as stage_name) ->
            validate_coding_dependency_requirement ~stage:stage_name
              ~depends_on_operation_ids
        | _ -> Ok ()
      in
      let chain =
        match U.member "chain" json with
        | (`Assoc _ as chain_json) -> (
            match get_string_opt chain_json "kind", get_string_opt chain_json "status" with
            | Some kind, Some status ->
                Some
                  {
                    kind;
                    backend = get_string_default chain_json "backend" "legacy";
                    chain_id = get_string_opt chain_json "chain_id";
                    goal = get_string_opt chain_json "goal";
                    run_id = get_string_opt chain_json "run_id";
                    status;
                    history_event =
                      (match U.member "history_event" chain_json with
                      | `Null -> None
                      | `Assoc _ as json -> Some json
                      | _ -> None);
                    mermaid = get_string_opt chain_json "mermaid";
                    preview_run =
                      (match U.member "preview_run" chain_json with
                      | `Null -> None
                      | `Assoc _ as json -> Some json
                      | _ -> None);
                    viewer_path = get_string_opt chain_json "viewer_path";
                    last_sync_at = get_string_opt chain_json "last_sync_at";
                  }
            | _ -> None)
        | _ -> None
      in
      let checkpoint_ref =
        match get_string_opt json "checkpoint_ref", chain with
        | Some value, _ -> Some value
        | None, Some { run_id = Some run_id; _ } -> Some run_id
        | None, _ -> None
      in
      let operation =
        {
          operation_id = next_operation_id ();
          objective;
          intent_id = Option.map (fun (intent : intent_record) -> intent.intent_id) intent_binding;
          assigned_unit_id;
          autonomy_level = get_string_default json "autonomy_level" "L4_Autonomous";
          policy_class = get_string_default json "policy_class" "strict";
          budget_class = get_string_default json "budget_class" "standard";
          workload_template;
          workload_profile;
          stage;
          artifact_scope;
          depends_on_operation_ids;
          search_strategy;
          detachment_session_id = get_string_opt json "detachment_session_id";
          trace_id = next_trace_id ();
          checkpoint_ref;
          active_goal_ids = get_string_list json "active_goal_ids";
          note = get_string_opt json "note";
          created_by = actor;
          source = "managed";
          status =
            (match
               (match get_string_opt json "status" with
               | Some value -> operation_status_of_string value
               | None -> None)
             with
            | Some value -> value
            | None -> Active);
          chain;
          created_at = Types.now_iso ();
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (operation :: operations);
      let _, _, units, _ = topology_units config in
      let _ =
        match operation_search_strategy operation with
        | Cp_search_fabric.Legacy -> sync_managed_detachments config units operation
        | Cp_search_fabric.Best_first_v1 -> []
      in
      touch_intent_from_operation config ~actor operation ~state:Active_intent;
      append_cp_event config ~trace_id:operation.trace_id ~event_type:"operation_started"
        ~operation_id:operation.operation_id ~unit_id:operation.assigned_unit_id ~actor
        (`Assoc
          [
            ("objective", `String operation.objective);
            ("intent_id", match operation.intent_id with Some value -> `String value | None -> `Null);
            ("autonomy_level", `String operation.autonomy_level);
            ("policy_class", `String operation.policy_class);
            ( "workload_template",
              match operation.workload_template with
              | Some value -> `String value
              | None -> `Null );
            ("workload_profile", `String (operation_workload_profile operation));
            ("stage", match operation.stage with Some value -> `String value | None -> `Null);
            ("artifact_scope", json_list_of_strings operation.artifact_scope);
            ("search_strategy", `String operation.search_strategy);
          ]);
      Ok operation

let checkpoint_operation config ~(actor : string) json =
  let operation_id =
    match get_string_opt json "operation_id" with
    | Some value -> value
    | None -> invalid_arg "operation_id is required"
  in
  let checkpoint_ref =
    match get_string_opt json "checkpoint_ref" with
    | Some value -> value
    | None -> invalid_arg "checkpoint_ref is required"
  in
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current ->
      let updated =
        {
          current with
          checkpoint_ref = Some checkpoint_ref;
          note =
            (match get_string_opt json "note", current.note with
            | Some note, _ -> Some note
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let next_operations =
        replace_operation operations updated
      in
      write_operations config next_operations;
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      touch_intent_from_operation config ~actor updated
        ~state:(intent_state_hint_of_operation_status updated);
      if operation_search_strategy updated = Cp_search_fabric.Best_first_v1 then
        update_search_stats_for_operation config updated ~outcome:`Success;
      append_cp_event config ~trace_id:updated.trace_id ~event_type:"operation_checkpointed"
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("checkpoint_ref", `String checkpoint_ref) ]);
      Ok updated

let pause_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Paused
           ~note:(get_string_opt json "note") ~event_type:"operation_paused")

let resume_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Active
           ~note:(get_string_opt json "note") ~event_type:"operation_resumed")

let stop_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Cancelled
           ~note:(get_string_opt json "note") ~event_type:"operation_stopped")

let finalize_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map
        (fun operation ->
          if operation_search_strategy operation = Cp_search_fabric.Best_first_v1 then
            update_search_stats_for_operation config operation ~outcome:`Success;
          operation_to_json operation)
        (update_operation_status config ~actor ~operation_id ~status:Completed
           ~note:(get_string_opt json "note") ~event_type:"operation_finalized")

let dispatch_plan_json config json =
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let operation_id = get_string_opt json "operation_id" in
  let operation =
    match operation_id with
    | Some value -> operation_by_id operations value
    | None -> None
  in
  let current_unit_id = Option.map (fun (op : operation_record) -> op.assigned_unit_id) operation in
  let strategy =
    match operation with
    | Some op -> operation_search_strategy op
    | None -> Cp_search_fabric.Legacy
  in
  let readiness =
    match operation with
    | Some op -> operation_readiness operations op
    | None -> Cp_search_fabric.Ready
  in
  let scored_candidates =
    match operation with
    | Some op when strategy = Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates config units operations op
    | Some op ->
        let preview_op = { op with search_strategy = "best_first_v1" } in
        operation_search_candidates config units operations preview_op
    | None -> []
  in
  let recommended_units =
    if scored_candidates <> [] then
      scored_candidates
      |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
             `Assoc
               [
                 ( "unit",
                   match lookup_unit units candidate.unit_id with
                   | Some unit -> unit_to_json unit
                   | None ->
                       `Assoc
                         [
                           ("unit_id", `String candidate.unit_id);
                           ("label", `String candidate.label);
                         ] );
                 ("score", `Float candidate.breakdown.total);
                 ( "score_breakdown",
                   Cp_search_fabric.breakdown_to_json candidate.breakdown );
                 ("routing_reason", `String candidate.routing_reason);
               ])
    else
      candidate_units_for_operation units operations current_unit_id
      |> List.filter_map (fun (unit : unit_record) ->
             match unit_guard_json config unit.unit_id with
             | Ok guard ->
                 Some
                   (`Assoc
                     [
                       ("unit", unit_to_json unit);
                       ("guard", guard);
                       ("score", `Null);
                       ("score_breakdown", `Null);
                       ("routing_reason", `String "legacy candidate ordering");
                     ])
             | Error _ -> None)
  in
  `Assoc
    [
      ("status", `String "ok");
      ("strategy", `String (Cp_search_fabric.strategy_to_string strategy));
      ( "readiness",
        match readiness with
        | Cp_search_fabric.Ready -> `String "ready"
        | Cp_search_fabric.Blocked _ -> `String "blocked" );
      ( "dependency_blockers",
        match readiness with
        | Cp_search_fabric.Ready -> `List []
        | Cp_search_fabric.Blocked blockers ->
            `List (List.map Cp_search_fabric.blocker_to_json blockers) );
      ("recommended_units", `List recommended_units);
      ("current_unit_id", match current_unit_id with Some value -> `String value | None -> `Null);
    ]

