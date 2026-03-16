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
