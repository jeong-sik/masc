open Tool_args
open Tool_team_session_support
open Tool_team_session_spawn
module Oas = Agent_sdk

let handle_start ctx args : result =
  let goal = get_string args "goal" "" in
  if String.trim goal = "" then
    (false, json_error "goal is required")
  else
    let duration_seconds =
      let raw_seconds = get_int args "duration_seconds" 0 in
      if raw_seconds > 0 then
        raw_seconds
      else
        let duration_minutes = get_int args "duration_minutes" 60 in
        max 1 duration_minutes * 60
    in
    let checkpoint_interval_sec = get_int args "checkpoint_interval_sec" 60 in
    let min_agents = get_int args "min_agents" 2 in
    let scale_profile = parse_scale_profile args in
    let control_profile = parse_control_profile ~scale_profile args in
    let auto_resume = get_bool args "auto_resume" true in
    let report_formats = parse_report_formats args in
    let execution_scope = parse_execution_scope args in
    let orchestration_mode = parse_orchestration_mode args in
    let communication_mode = parse_communication_mode args in
    let model_cascade = get_string_list args "model_cascade" in
    let fallback_policy = parse_fallback_policy args in
    let instruction_profile = parse_instruction_profile args in
    let alert_channel = parse_alert_channel args in
    let agents = get_agent_names args "agents" in
    let operation_id = get_string_opt args "operation_id" in
    match
      Team_session_engine_eio.start_session ~sw:ctx.sw ~clock:ctx.clock
        ~config:ctx.config ~created_by:ctx.agent_name ~goal ~duration_seconds
        ~execution_scope ~checkpoint_interval_sec ~min_agents
        ~scale_profile ~control_profile
        ~orchestration_mode ~communication_mode ~model_cascade ~fallback_policy
        ~instruction_profile ~alert_channel ~auto_resume ~report_formats
        ~agent_names:agents ~operation_id
    with
    | Ok json -> (true, json_ok [ ("result", json) ])
    | Error e -> (false, json_error e)

let handle_status ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match Team_session_engine_eio.status_session ~config:ctx.config ~session_id with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_stop ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "manual_stop" in
          let generate_report = get_bool args "generate_report" true in
          (match
             Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
               ~reason ~generate_report
           with
          | Ok json ->
              let linked_result =
                match
                  Autoresearch.load_swarm_link_by_session
                    ~base_path:ctx.config.base_path session_id
                with
                | None -> None
                | Some link ->
                    Autoresearch.stop_loop ~base_path:ctx.config.base_path
                      ~reason:(Printf.sprintf "team_session_stop:%s" reason)
                      link.loop_id
                    |> Option.map (fun (state : Autoresearch.loop_state) ->
                           `Assoc
                             [
                               ("loop_id", `String state.loop_id);
                               ( "status",
                                 `String
                                   (Autoresearch.status_to_string state.status) );
                               ("current_cycle", `Int state.current_cycle);
                               ("best_score", `Float state.best_score);
                             ])
              in
              let json =
                match json with
                | `Assoc fields -> (
                    match linked_result with
                    | Some linked ->
                        `Assoc
                          (List.remove_assoc "linked_autoresearch" fields
                          @ [ ("linked_autoresearch", linked) ])
                    | None -> json)
                | _ -> json
              in
              (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_report ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let force_regenerate = get_bool args "force_regenerate" false in
          (match
             Team_session_engine_eio.generate_report ~config:ctx.config ~session_id
               ~force_regenerate
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_list ctx args : result =
  let limit = get_int args "limit" 20 in
  match parse_status_filter args with
  | Error e -> (false, json_error e)
  | Ok status_filter -> (
      match
        Team_session_engine_eio.list_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~status_filter ~limit
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_compare ctx args : result =
  match
    ( get_valid_session_id_key args "base_session_id",
      get_valid_session_id_key args "target_session_id" )
  with
  | Ok base_session_id, Ok target_session_id -> (
      match
        Team_session_engine_eio.compare_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~base_session_id
          ~target_session_id
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))
  | Error e, _ -> (false, json_error e)
  | _, Error e -> (false, json_error e)

let handle_turn ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match parse_turn_kind args with
          | Error e -> (false, json_error e)
          | Ok turn_kind ->
              let message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              (match
                 record_session_turn_json ~config:ctx.config ~session_id
                   ~actor:ctx.agent_name ~turn_kind ~message ~target_agent
                   ~task_title ~task_description ~task_priority
               with
              | Ok json -> (true, json_ok [ ("result", json) ])
              | Error e -> (false, json_error e))))

(* --- Extracted closures from handle_step --- *)

type step_env = {
  config : Room.config;
  session_id : string;
  actor : string;
  wait_mode : Team_session_types.wait_mode;
}

let append_spawn_event (env : step_env) ?worker_run_id ?spawn_agent ?runtime_actor ?spawn_role
    ?spawn_model ?execution_scope ?worker_class ?worker_size
    ?worker_backend ?wait_mode ?trace_capability
    ?parent_actor ?capsule_mode
    ?runtime_pool ?lane_id ?controller_level ?control_domain
    ?supervisor_actor ?model_tier ?task_profile ?risk_level
    ?routing_confidence ?routing_reason ?assigned_runtime
    ?spawn_selection_note ?tool_names ?tool_call_count ~success
    ?exit_code
    ?elapsed_ms ?output_preview ?error () =
  let _ = spawn_agent and _ = spawn_model and _ = model_tier in
  let detail =
    `Assoc
      [
        ("actor", `String env.actor);
        ("worker_run_id", Option.fold ~none:`Null ~some:(fun s -> `String s) worker_run_id);
        ( "runtime_actor",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            runtime_actor );
        ( "spawn_role",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            spawn_role );
        ( "execution_scope",
          Option.fold ~none:`Null
            ~some:(fun scope ->
              `String
                (Team_session_types.execution_scope_to_string
                   scope))
            execution_scope );
        ( "worker_class",
          Option.fold ~none:`Null
            ~some:(fun kind ->
              `String
                (Team_session_types.worker_class_to_string kind))
            worker_class );
        ( "worker_size",
          Option.fold ~none:`Null
            ~some:(fun size ->
              `String
                (Team_session_types.worker_size_to_string size))
            worker_size );
        ( "worker_backend",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            worker_backend );
        ( "wait_mode",
          Option.fold ~none:`Null ~some:(fun mode -> `String mode)
            wait_mode );
        ( "trace_capability",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            trace_capability );
        ( "parent_actor",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            parent_actor );
        ( "capsule_mode",
          Option.fold ~none:`Null
            ~some:(fun mode ->
              `String
                (Team_session_types.capsule_mode_to_string mode))
            capsule_mode );
        ( "runtime_pool",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            runtime_pool );
        ( "lane_id",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            lane_id );
        ( "controller_level",
          Option.fold ~none:`Null
            ~some:(fun level ->
              `String
                (Team_session_types.controller_level_to_string
                   level))
            controller_level );
        ( "control_domain",
          Option.fold ~none:`Null
            ~some:(fun domain ->
              `String
                (Team_session_types.control_domain_to_string
                   domain))
            control_domain );
        ( "supervisor_actor",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            supervisor_actor );
        ( "task_profile",
          Option.fold ~none:`Null
            ~some:(fun profile ->
              `String
                (Team_session_types.task_profile_to_string
                   profile))
            task_profile );
        ( "risk_level",
          Option.fold ~none:`Null
            ~some:(fun level ->
              `String
                (Team_session_types.risk_level_to_string level))
            risk_level );
        ("routing_confidence", float_opt_to_json routing_confidence);
        ( "routing_reason",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            routing_reason );
        ( "assigned_runtime",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            assigned_runtime );
        ( "spawn_selection_note",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            spawn_selection_note );
        ( "tool_names",
          Option.fold ~none:(`List [])
            ~some:(fun names ->
              `List (List.map (fun name -> `String name) names))
            tool_names );
        ( "tool_call_count",
          Option.fold ~none:`Null ~some:(fun n -> `Int n)
            tool_call_count );
        ("success", `Bool success);
        ("exit_code", int_opt_to_json exit_code);
        ("elapsed_ms", int_opt_to_json elapsed_ms);
        ( "output_preview",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            output_preview );
        ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
        ("ts_iso", `String (Types.now_iso ()));
      ]
  in
  Team_session_store.append_event env.config env.session_id
    ~event_type:"team_step_spawn" ~detail

let append_delegate_event (env : step_env) ~worker_run_id ~worker_name ~delegate_prompt ~success
    ?execution_scope ?wait_mode ?trace_capability
    ?resolved_runtime ?resolved_model ?routing_reason
    ?tool_names ?tool_call_count ?output_preview ?error () =
  Team_session_store.append_event env.config env.session_id
    ~event_type:"team_step_delegate"
    ~detail:
      (`Assoc
        [
          ("actor", `String env.actor);
          ("worker_run_id", `String worker_run_id);
          ("target_agent", `String worker_name);
          ("delegate_prompt", `String delegate_prompt);
          ("worker_backend", `String "local");
          ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
          ("wait_mode", Option.fold ~none:`Null ~some:(fun mode -> `String mode) wait_mode);
          ("trace_capability", Option.fold ~none:`Null ~some:(fun s -> `String s) trace_capability);
          ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
          ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_model);
          ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
          ("success", `Bool success);
          ( "tool_names",
            Option.fold ~none:(`List [])
              ~some:(fun names ->
                `List (List.map (fun name -> `String name) names))
              tool_names );
          ( "tool_call_count",
            Option.fold ~none:`Null ~some:(fun n -> `Int n)
              tool_call_count );
          ( "output_preview",
            Option.fold ~none:`Null ~some:(fun s -> `String s)
              output_preview );
          ( "error",
            Option.fold ~none:`Null ~some:(fun s -> `String s)
              error );
          ("ts_iso", `String (Types.now_iso ()));
        ])

let append_spawn_requested_event (env : step_env) ~worker_run_id prepared =
  Team_session_store.append_event env.config env.session_id
    ~event_type:"team_step_spawn_requested"
    ~detail:
      (`Assoc
        [
          ("actor", `String env.actor);
          ("worker_run_id", `String worker_run_id);
          ( "runtime_actor",
            Option.fold ~none:`Null
              ~some:(fun s -> `String s)
              prepared.runtime_actor_name );
          ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
          ("worker_backend", if is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
          ("wait_mode", `String (Team_session_types.wait_mode_to_string env.wait_mode));
          ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
          ("resolved_model", `String prepared.runtime_model.model_id);
          ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
          ("ts_iso", `String (Types.now_iso ()));
        ])

let append_delegate_requested_event (env : step_env) ~worker_run_id ~worker_name ~delegate_prompt =
  Team_session_store.append_event env.config env.session_id
    ~event_type:"team_step_delegate_requested"
    ~detail:
      (`Assoc
        [
          ("actor", `String env.actor);
          ("worker_run_id", `String worker_run_id);
          ("target_agent", `String worker_name);
          ("delegate_prompt", `String delegate_prompt);
          ("worker_backend", `String "local");
          ("wait_mode", `String (Team_session_types.wait_mode_to_string env.wait_mode));
          ("ts_iso", `String (Types.now_iso ()));
        ])

let persist_worker_run_snapshot (env : step_env) ~worker_run_id ~worker_name
    ~mode ~wait_mode ?execution_scope ?tool_names ?tool_call_count
    ?requested_worker_class ?requested_worker_size
    ?resolved_runtime ?resolved_model ?routing_reason
    ~status
    ~success ?output_preview ?error ?trace_capability ?trace_ref
    ?trace_summary ?trace_validation ?evidence_session_id
    () =
  let checkpoint_path =
    Team_session_store.worker_container_checkpoint_path env.config
      env.session_id worker_name
  in
  let oas_evidence =
    Option.bind evidence_session_id (fun evidence_session_id ->
        oas_worker_evidence_payload ~config:env.config
          ~evidence_session_id)
  in
  let effective_trace_ref =
    match Option.bind oas_evidence (fun payload -> payload.trace_ref) with
    | Some _ as value -> value
    | None -> trace_ref
  in
  let effective_trace_summary =
    match
      Option.bind oas_evidence (fun payload ->
          payload.trace_summary_json)
    with
    | Some _ as value -> value
    | None -> trace_summary
  in
  let effective_trace_validation =
    match
      Option.bind oas_evidence (fun payload ->
          payload.trace_validation_json)
    with
    | Some _ as value -> value
    | None -> trace_validation
  in
  let oas_worker =
    Option.bind oas_evidence (fun payload -> payload.worker)
  in
  let effective_status =
    match oas_worker with
    | Some worker -> Oas.Sessions.worker_status_to_yojson worker.status
    | None -> worker_run_status_to_json status
  in
  let trace_capability =
    match trace_capability with
    | _ when Option.is_some oas_worker ->
        Option.value ~default:"summary_only"
          (Option.map
             (fun worker ->
               oas_trace_capability_to_string
                 worker.Oas.Sessions.trace_capability)
             oas_worker)
    | Some value -> value
    | None when Option.is_some effective_trace_ref -> "raw"
    | None -> ignore checkpoint_path; "summary_only"
  in
  let effective_tool_names =
    match oas_worker with
    | Some worker when worker.tool_names <> [] -> worker.tool_names
    | _ -> Option.value ~default:[] tool_names
  in
  let effective_resolved_model =
    match oas_worker with
    | Some worker -> (
        match worker.resolved_model with
        | Some _ as value -> value
        | None -> resolved_model)
    | None -> resolved_model
  in
  let effective_error =
    match oas_worker with
    | Some worker -> (
        match worker.failure_reason with
        | Some _ as value -> value
        | None -> (
            match worker.error with
            | Some _ as value -> value
            | None -> error))
    | None -> error
  in
  let effective_output_preview =
    match oas_worker with
    | Some worker -> (
        match worker.final_text with
        | Some final_text when String.trim final_text <> "" ->
            Some (truncate_for_event final_text)
        | _ -> output_preview)
    | None -> output_preview
  in
  if Room_utils.path_exists env.config checkpoint_path then
    Team_session_store.save_worker_run_checkpoint_text env.config
      env.session_id worker_run_id
      (Team_session_store.read_text_file checkpoint_path);
  Team_session_store.save_worker_run_meta_json env.config env.session_id
    worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String worker_name);
        ("mode", `String mode);
        ("status", effective_status);
        ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
        ("trace_capability", `String trace_capability);
        ("success", `Bool success);
        ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
        ("requested_worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) requested_worker_class);
        ("requested_worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) requested_worker_size);
        ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
        ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_resolved_model);
        ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
        ("tool_names", `List (List.map (fun name -> `String name) effective_tool_names));
        ("tool_call_count", Option.fold ~none:`Null ~some:(fun n -> `Int n) tool_call_count);
        ("output_preview", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_output_preview);
        ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_error);
        ("trace_ref", Option.fold ~none:`Null ~some:Oas.Raw_trace.run_ref_to_yojson effective_trace_ref);
        ("trace_summary", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_summary);
        ("trace_validation", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_validation);
        ("evidence_session_id", Option.fold ~none:`Null ~some:(fun s -> `String s) evidence_session_id);
        ("oas_worker_run", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.worker_json)));
        ("session_conformance", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.conformance_json)));
        ("validated", Option.fold ~none:`Null ~some:(fun worker -> `Bool worker.Oas.Sessions.validated) oas_worker);
        ("final_text", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.final_text) oas_worker);
        ("stop_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.stop_reason) oas_worker);
        ("failure_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.failure_reason) oas_worker);
        ("ts_iso", `String (Types.now_iso ()));
      ])

(* --- End extracted closures --- *)

let handle_step ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let session_opt = Team_session_store.load_session ctx.config session_id in
          let spawn_specs_result = parse_step_spawn_specs args in
          match spawn_specs_result with
          | Error e -> (false, json_error e)
          | Ok raw_spawn_specs ->
              let spawn_specs =
                match session_opt with
                | Some session ->
                    annotate_control_hierarchy_for_session session raw_spawn_specs
                | None -> raw_spawn_specs
              in
              let delegate_prompt_opt = get_string_opt args "delegate_prompt" in
              let turn_kind_result =
                if spawn_specs <> [] || Option.is_some delegate_prompt_opt then
                  parse_turn_kind_opt args
                else
                  match parse_turn_kind args with
                  | Ok kind -> Ok (Some kind)
                  | Error e -> Error e
              in
              match turn_kind_result with
              | Error e -> (false, json_error e)
              | Ok turn_kind_opt ->
              let actor_result =
                match get_string_opt args "actor" with
                | None -> Ok ctx.agent_name
                | Some actor_name
                  when String.equal (String.trim actor_name) ctx.agent_name ->
                    Ok ctx.agent_name
                | Some _ ->
                    Error
                      "actor must match the authenticated caller; omit actor to use the current agent"
              in
              match actor_result with
              | Error e -> (false, json_error e)
              | Ok actor ->
              let wait_mode = parse_wait_mode args in
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let delegate_prompt = delegate_prompt_opt in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              (* step_env + 5 extracted closures: see module-level definitions above *)
              let env = { config = ctx.config; session_id; actor; wait_mode } in
              let release_prepared_runtime (prepared : prepared_spawn) ~success
                  ?error ?latency_ms () =
                match prepared.runtime_lease with
                | Some lease ->
                    Local_runtime_pool.release lease ~success ?error ?latency_ms ()
                | None -> ()
              in
              let release_all_prepared prepareds ~error =
                List.iter
                  (fun prepared ->
                    release_prepared_runtime prepared ~success:false ~error ())
                  prepareds
              in
              let prepare_spawn (spec : spawn_spec) =
                let runtime_actor_name =
                  if is_local_spawn_agent spec.spawn_agent then
                    Some
                      (derived_llama_runtime_actor ~session_id
                         ~prompt:spec.spawn_prompt)
                  else
                    None
                in
                let runtime_model =
                  if is_local_spawn_agent spec.spawn_agent then
                    let model_name =
                      match spec.spawn_model with
                      | Some model_name -> Some model_name
                      | None ->
                          let default_model =
                            Llm_client.default_local_model_spec ()
                          in
                          Some default_model.model_id
                    in
                    match model_name with
                    | None -> Error "local worker model resolution failed"
                    | Some model_name -> (
                        match
                          Local_runtime_pool.acquire
                            ?preferred_pool:spec.runtime_pool
                            ~model_name:(Some model_name) ()
                        with
                        | Ok assignment ->
                            Ok
                              ( Local_runtime_pool.model_spec_of_assignment
                                  assignment,
                                Some assignment.lease,
                                Some assignment.runtime_id )
                        | Error err -> Error err)
                  else
                    Ok (Llm_client.default_local_model_spec (), None, None)
                in
                match runtime_model with
                | Error e -> Error (spec, runtime_actor_name, e)
                | Ok (runtime_model, runtime_lease, assigned_runtime) ->
                    Ok
                      {
                        worker_run_id = make_worker_run_id ();
                        spec;
                        runtime_actor_name;
                        runtime_model;
                        runtime_lease;
                        assigned_runtime;
                      }
              in
              let prepared_spawns_result =
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | spec :: rest -> (
                      match prepare_spawn spec with
                      | Ok prepared -> loop (prepared :: acc) rest
                      | Error (failed_spec, runtime_actor_name, msg) ->
                          release_all_prepared (List.rev acc) ~error:msg;
                          append_spawn_event env ~spawn_agent:failed_spec.spawn_agent
                            ?runtime_actor:runtime_actor_name
                            ?spawn_role:failed_spec.spawn_role
                            ?spawn_model:failed_spec.spawn_model
                            ?execution_scope:
                              (effective_execution_scope_of_spec failed_spec)
                            ?worker_class:failed_spec.worker_class
                            ?worker_size:(worker_size_of_spec failed_spec)
                            ?worker_backend:
                              (if is_local_spawn_agent failed_spec.spawn_agent
                               then Some "local" else None)
                            ?parent_actor:failed_spec.parent_actor
                            ?capsule_mode:failed_spec.capsule_mode
                            ?runtime_pool:failed_spec.runtime_pool
                            ?lane_id:failed_spec.lane_id
                            ?controller_level:(inferred_controller_level_of_spec failed_spec)
                            ?control_domain:failed_spec.control_domain
                            ?supervisor_actor:failed_spec.supervisor_actor
                            ?model_tier:failed_spec.model_tier
                            ?task_profile:failed_spec.task_profile
                            ?risk_level:failed_spec.risk_level
                            ?routing_confidence:failed_spec.routing_confidence
                            ?routing_reason:failed_spec.routing_reason
                            ?spawn_selection_note:failed_spec.spawn_selection_note
                            ~success:false ~error:msg ();
                          Error msg)
                in
                loop [] spawn_specs
              in
              let spawn_result_json =
                match prepared_spawns_result with
                | Error msg -> Some (`Assoc [ ("error", `String msg) ])
                | Ok [] -> None
                | Ok prepared_spawns ->
                    let planned_workers =
                      List.map
                        (fun prepared ->
                          planned_worker_of_spec
                            ?runtime_actor:prepared.runtime_actor_name
                            prepared.spec)
                        prepared_spawns
                    in
                    let planning_error =
                      match
                        register_planned_workers ctx.config session_id
                          planned_workers
                      with
                      | Error msg -> Some msg
                      | Ok () -> None
                    in
                    match planning_error with
                    | Some msg ->
                        List.iter
                          (fun prepared ->
                            release_prepared_runtime prepared ~success:false
                              ~error:msg ();
                            append_spawn_event env
                              ~spawn_agent:prepared.spec.spawn_agent
                              ?runtime_actor:prepared.runtime_actor_name
                              ?spawn_role:prepared.spec.spawn_role
                              ?spawn_model:prepared.spec.spawn_model
                              ?execution_scope:
                                (effective_execution_scope_of_spec prepared.spec)
                              ?worker_class:prepared.spec.worker_class
                              ?worker_size:(worker_size_of_spec prepared.spec)
                              ?worker_backend:
                                (if is_local_spawn_agent prepared.spec.spawn_agent
                                 then Some "local" else None)
                              ?parent_actor:prepared.spec.parent_actor
                              ?capsule_mode:prepared.spec.capsule_mode
                              ?runtime_pool:prepared.spec.runtime_pool
                              ?lane_id:prepared.spec.lane_id
                              ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                              ?control_domain:prepared.spec.control_domain
                              ?supervisor_actor:prepared.spec.supervisor_actor
                              ?model_tier:prepared.spec.model_tier
                              ?task_profile:prepared.spec.task_profile
                              ?risk_level:prepared.spec.risk_level
                              ?routing_confidence:prepared.spec.routing_confidence
                              ?routing_reason:prepared.spec.routing_reason
                              ?assigned_runtime:prepared.assigned_runtime
                              ?spawn_selection_note:
                                prepared.spec.spawn_selection_note
                              ~success:false ~error:msg ())
                          prepared_spawns;
                        Some (`Assoc [ ("error", `String msg) ])
                    | None ->
                        match ctx.proc_mgr with
                        | None ->
                            let msg =
                              "process manager unavailable for team step spawn"
                            in
                            List.iter
                              (fun prepared ->
                                release_prepared_runtime prepared ~success:false
                                  ~error:msg ();
                                append_spawn_event env
                                  ~worker_run_id:prepared.worker_run_id
                                  ~spawn_agent:prepared.spec.spawn_agent
                                  ?runtime_actor:prepared.runtime_actor_name
                                  ?spawn_role:prepared.spec.spawn_role
                                  ?spawn_model:prepared.spec.spawn_model
                                  ?execution_scope:
                                    (effective_execution_scope_of_spec prepared.spec)
                                  ?worker_class:prepared.spec.worker_class
                                  ?worker_size:(worker_size_of_spec prepared.spec)
                                  ?worker_backend:
                                    (if is_local_spawn_agent prepared.spec.spawn_agent
                                     then Some "local" else None)
                                  ?parent_actor:prepared.spec.parent_actor
                                  ?capsule_mode:prepared.spec.capsule_mode
                                  ?runtime_pool:prepared.spec.runtime_pool
                                  ?lane_id:prepared.spec.lane_id
                                  ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                  ?control_domain:prepared.spec.control_domain
                                  ?supervisor_actor:prepared.spec.supervisor_actor
                                  ?model_tier:prepared.spec.model_tier
                                  ?task_profile:prepared.spec.task_profile
                                  ?risk_level:prepared.spec.risk_level
                                  ?routing_confidence:
                                    prepared.spec.routing_confidence
                                  ?routing_reason:prepared.spec.routing_reason
                                  ?assigned_runtime:prepared.assigned_runtime
                                  ?spawn_selection_note:
                                    prepared.spec.spawn_selection_note
                                  ~success:false ~error:msg ())
                              prepared_spawns;
                            Some (`Assoc [ ("error", `String msg) ])
                        | Some pm ->
                            let rec ensure_all = function
                              | [] -> Ok ()
                              | prepared :: rest -> (
                                  match prepared.runtime_actor_name with
                                  | None -> ensure_all rest
                                  | Some worker_actor -> (
                                      match
                                        ensure_session_actor ctx.config
                                          session_id worker_actor
                                      with
                                      | Ok () -> ensure_all rest
                                      | Error msg -> Error msg))
                            in
                            match ensure_all prepared_spawns with
                             | Error msg ->
                                 List.iter
                                   (fun prepared ->
                                     release_prepared_runtime prepared
                                       ~success:false ~error:msg ();
                                       append_spawn_event env
                                         ~worker_run_id:prepared.worker_run_id
                                         ~spawn_agent:prepared.spec.spawn_agent
                                         ?runtime_actor:prepared.runtime_actor_name
                                         ?spawn_role:prepared.spec.spawn_role
                                         ?spawn_model:prepared.spec.spawn_model
                                         ?execution_scope:
                                           (effective_execution_scope_of_spec prepared.spec)
                                         ?worker_class:prepared.spec.worker_class
                                         ?worker_size:(worker_size_of_spec prepared.spec)
                                         ?worker_backend:
                                           (if is_local_spawn_agent prepared.spec.spawn_agent
                                            then Some "local" else None)
                                         ?parent_actor:prepared.spec.parent_actor
                                       ?capsule_mode:prepared.spec.capsule_mode
                                       ?runtime_pool:prepared.spec.runtime_pool
                                       ?lane_id:prepared.spec.lane_id
                                       ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                       ?control_domain:prepared.spec.control_domain
                                       ?supervisor_actor:prepared.spec.supervisor_actor
                                       ?model_tier:prepared.spec.model_tier
                                       ?task_profile:prepared.spec.task_profile
                                       ?risk_level:prepared.spec.risk_level
                                       ?routing_confidence:
                                         prepared.spec.routing_confidence
                                       ?routing_reason:
                                         prepared.spec.routing_reason
                                       ?assigned_runtime:prepared.assigned_runtime
                                       ?spawn_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~success:false ~error:msg ())
                                   prepared_spawns;
                                 Some (`Assoc [ ("error", `String msg) ])
                             | Ok () ->
                                 let execute_spawn index prepared =
                                   let spawn_result =
                                     Spawn_eio.spawn ~sw:ctx.sw ~proc_mgr:pm
                                       ~agent_name:prepared.spec.spawn_agent
                                       ~prompt:prepared.spec.spawn_prompt
                                       ~timeout_seconds:
                                         prepared.spec.spawn_timeout_seconds
                                       ~room_config:ctx.config
                                       ?runtime_agent_name:
                                         prepared.runtime_actor_name
                                       ~runtime_model:prepared.runtime_model
                                       ?runtime_role:prepared.spec.spawn_role
                                       ?runtime_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~worker_run_id:prepared.worker_run_id
                                       ?worker_class:prepared.spec.worker_class
                                       ?worker_size:(worker_size_of_spec prepared.spec)
                                       ?execution_scope:
                                         (effective_execution_scope_of_spec prepared.spec)
                                       ?thinking_enabled:prepared.spec.thinking_enabled
                                       ?max_turns:prepared.spec.max_turns
                                       ~runtime_session_id:session_id ()
                                   in
                                 let output_preview =
                                     truncate_for_event spawn_result.output
                                   in
                                   let trace_summary_json, trace_validation_json =
                                     match spawn_result.raw_trace_run with
                                     | Some run_ref -> (
                                         match
                                           raw_trace_session_payloads
                                             ~config:ctx.config
                                             ~fallback_session_id:session_id
                                             run_ref
                                         with
                                         | Some pair -> (Some (fst pair), Some (snd pair))
                                         | None -> (None, None))
                                     | None -> (None, None)
                                   in
                                   (match spawn_result.success with
                                   | true ->
                                       release_prepared_runtime prepared
                                         ~success:true
                                         ~latency_ms:spawn_result.elapsed_ms ()
                                   | false ->
                                       release_prepared_runtime prepared
                                         ~success:false
                                         ~error:spawn_result.output
                                         ~latency_ms:spawn_result.elapsed_ms ());
                                   persist_worker_run_snapshot env
                                     ~worker_run_id:prepared.worker_run_id
                                     ~worker_name:
                                       (Option.value
                                          ~default:(Printf.sprintf "spawn-%d" index)
                                          prepared.runtime_actor_name)
                                     ~mode:"spawn" ~wait_mode
                                     ~status:
                                       (if spawn_result.success then `Completed else `Failed)
                                     ?execution_scope:
                                       (effective_execution_scope_of_spec prepared.spec)
                                     ?requested_worker_class:prepared.spec.worker_class
                                     ?requested_worker_size:(worker_size_of_spec prepared.spec)
                                     ?resolved_runtime:prepared.assigned_runtime
                                     ~resolved_model:prepared.runtime_model.model_id
                                     ?routing_reason:prepared.spec.routing_reason
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~output_preview
                                     ~evidence_session_id:
                                       (Local_agent_eio
                                        .oas_worker_evidence_session_id
                                          ~worker_run_id:
                                            prepared.worker_run_id)
                                     ?trace_ref:spawn_result.raw_trace_run
                                     ?trace_summary:trace_summary_json
                                     ?trace_validation:trace_validation_json
                                       ~trace_capability:
                                       (if Option.is_some spawn_result.raw_trace_run then
                                          "raw"
                                        else if is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ();
                                   append_spawn_event env
                                     ~worker_run_id:prepared.worker_run_id
                                     ~spawn_agent:prepared.spec.spawn_agent
                                     ?runtime_actor:prepared.runtime_actor_name
                                     ?spawn_role:prepared.spec.spawn_role
                                     ?spawn_model:prepared.spec.spawn_model
                                     ?execution_scope:
                                       (effective_execution_scope_of_spec prepared.spec)
                                     ?worker_class:prepared.spec.worker_class
                                     ?worker_size:(worker_size_of_spec prepared.spec)
                                     ?worker_backend:
                                       (if is_local_spawn_agent prepared.spec.spawn_agent
                                        then Some "local" else None)
                                     ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                     ~trace_capability:
                                       (if is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ?parent_actor:prepared.spec.parent_actor
                                     ?capsule_mode:prepared.spec.capsule_mode
                                     ?runtime_pool:prepared.spec.runtime_pool
                                     ?lane_id:prepared.spec.lane_id
                                     ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                     ?control_domain:prepared.spec.control_domain
                                     ?supervisor_actor:prepared.spec.supervisor_actor
                                     ?model_tier:prepared.spec.model_tier
                                     ?task_profile:prepared.spec.task_profile
                                     ?risk_level:prepared.spec.risk_level
                                     ?routing_confidence:prepared.spec.routing_confidence
                                     ?routing_reason:prepared.spec.routing_reason
                                     ?assigned_runtime:prepared.assigned_runtime
                                     ?spawn_selection_note:
                                       prepared.spec.spawn_selection_note
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~exit_code:spawn_result.exit_code
                                     ~elapsed_ms:spawn_result.elapsed_ms
                                     ~output_preview ();
                                   (match
                                      ( spawn_result.success,
                                        prepared.runtime_actor_name,
                                        auto_note_message_of_spawn_output
                                          spawn_result.output )
                                    with
                                   | true, Some worker_actor, Some auto_note
                                     when not
                                            (session_has_turn_for_actor
                                               ctx.config session_id worker_actor) ->
                                       ignore
                                         (record_session_turn_json
                                            ~config:ctx.config ~session_id
                                            ~actor:worker_actor
                                            ~turn_kind:Team_session_types.Turn_note
                                            ~message:(Some auto_note)
                                            ~target_agent:None
                                            ~task_title:None
                                            ~task_description:None
                                            ~task_priority:3)
                                   | _ -> ());
                                   (match (spawn_result.success, prepared.runtime_actor_name) with
                                   | false, Some worker_actor ->
                                       ignore
                                         (reconcile_failed_spawn_actor
                                            ctx.config session_id worker_actor)
                                   | _ -> ());
                                   `Assoc
                                     [
                                       ("worker_run_id", `String prepared.worker_run_id);
                                       ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                       ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                       ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) (effective_execution_scope_of_spec prepared.spec));
                                       ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) prepared.spec.thinking_enabled);
                                       ("max_turns", Option.fold ~none:`Null ~some:(fun n -> `Int n) prepared.spec.max_turns);
                                       ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                       ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (worker_size_of_spec prepared.spec));
                                       ("worker_backend", if is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                                       ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                       ("status", `String "completed");
                                       ("trace_capability", `String (if Option.is_some spawn_result.raw_trace_run then "raw" else "summary_only"));
                                       ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                       ("resolved_model", `String prepared.runtime_model.model_id);
                                       ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                       ("tool_call_count", `Int spawn_result.tool_call_count);
                                       ("tool_names", `List (List.map (fun name -> `String name) spawn_result.tool_names));
                                       ("success", `Bool spawn_result.success);
                                       ("elapsed_ms", `Int spawn_result.elapsed_ms);
                                       ("output_preview", `String output_preview);
                                     ]
                                 in
                                 (match wait_mode with
                                 | Team_session_types.Wait_background ->
                                     let sw_bg =
                                       Option.value ~default:ctx.sw
                                         (Eio_context.get_switch_opt ())
                                     in
                                     List.iter
                                       (fun prepared ->
                                         append_spawn_requested_event env
                                           ~worker_run_id:prepared.worker_run_id
                                           prepared;
                                         Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                             ignore (execute_spawn 0 prepared)))
                                       prepared_spawns;
                                     let accepted =
                                       prepared_spawns
                                       |> List.map (fun prepared ->
                                              `Assoc
                                                [
                                                  ("worker_run_id", `String prepared.worker_run_id);
                                                  ("status", `String "accepted");
                                                  ("wait_mode", `String "background");
                                                  ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                                  ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                                  ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                                  ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (worker_size_of_spec prepared.spec));
                                                  ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                                  ("resolved_model", `String prepared.runtime_model.model_id);
                                                  ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                                  ("ready", `Bool false);
                                                ])
                                     in
                                     Some
                                       (if List.length accepted = 1 then
                                          List.hd accepted
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length accepted));
                                              ("results", `List accepted);
                                            ])
                                 | Team_session_types.Wait_blocking ->
                                     let results =
                                       Array.make (List.length prepared_spawns) None
                                     in
                                     Eio.Fiber.all
                                       (List.mapi
                                          (fun index prepared () ->
                                            results.(index) <- Some (execute_spawn index prepared))
                                          prepared_spawns);
                                     let spawn_results =
                                       results |> Array.to_list
                                       |> List.filter_map (fun item -> item)
                                     in
                                     Some
                                       (if List.length spawn_results = 1 then
                                          List.hd spawn_results
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length spawn_results));
                                              ("results", `List spawn_results);
                                            ]))
              in
              let spawn_error =
                match spawn_result_json with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Some e
                    | _ -> None)
                | _ -> None
              in
              match spawn_error with
              | Some e -> (false, json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        record_session_turn_json ~config:ctx.config ~session_id
                          ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, json_error e)
                  | Ok turn_json ->
                      let delegate_result_json =
                        match (delegate_prompt, target_agent) with
                        | None, _ -> None
                        | Some _, _ when spawn_specs <> [] ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "delegate_prompt cannot be combined with worker spawn" );
                                ])
                        | Some _, None ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "target_agent is required when delegate_prompt is provided" );
                                ])
                        | Some delegate_prompt, Some target_agent -> (
                            match session_opt with
                            | None ->
                                Some
                                  (`Assoc
                                    [
                                      ("error", `String "team session not found");
                                    ])
                            | Some session -> (
                                match
                                  resolve_target_worker_name ctx.config session
                                    target_agent
                                with
                                | None ->
                                    Some
                                      (`Assoc
                                        [
                                          ( "error",
                                            `String
                                              "target_agent did not match a known worker container"
                                          );
                                        ])
                                | Some worker_name -> (
                                    let worker_run_id = make_worker_run_id () in
                                    let execution_scope =
                                      Option.bind session_opt (fun session ->
                                          List.find_map
                                            (fun w ->
                                              match
                                                w.Team_session_types.runtime_actor
                                              with
                                              | Some actor
                                                when String.equal actor
                                                       worker_name ->
                                                  w.execution_scope
                                              | _ -> None)
                                            session.planned_workers)
                                    in
                                    let run_delegate () =
                                      match
                                        Local_agent_eio.continue_worker ~sw:ctx.sw
                                          ~base_path:ctx.config.base_path
                                          ~room_config:(Some ctx.config)
                                          ~worker_name ~team_session_id:session_id
                                          ~worker_run_id
                                          ~prompt:delegate_prompt ()
                                      with
                                      | Ok run_result ->
                                          let output_preview =
                                            truncate_for_event run_result.output
                                          in
                                          let trace_summary_json, trace_validation_json =
                                            match run_result.raw_trace_run with
                                            | Some run_ref -> (
                                                match
                                                  raw_trace_session_payloads
                                                    ~config:ctx.config
                                                    ~fallback_session_id:session_id
                                                    run_ref
                                                with
                                                | Some pair -> (Some (fst pair), Some (snd pair))
                                                | None -> (None, None))
                                            | None -> (None, None)
                                          in
                                          persist_worker_run_snapshot env
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate"
                                            ~wait_mode ?execution_scope
                                            ~status:`Completed
                                            ~resolved_model:run_result.model_used
                                            ~resolved_runtime:"local"
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~success:true ~output_preview
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ?trace_ref:run_result.raw_trace_run
                                            ?trace_summary:trace_summary_json
                                            ?trace_validation:trace_validation_json
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only") ();
                                          append_delegate_event env ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only")
                                            ~resolved_runtime:"local"
                                            ~resolved_model:run_result.model_used
                                            ~success:true
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~routing_reason:
                                              (Option.value ~default:"continued_worker"
                                                 (List.find_map
                                                    (fun w ->
                                                      match
                                                        w.Team_session_types.runtime_actor
                                                      with
                                                      | Some actor
                                                        when String.equal actor worker_name ->
                                                            w.routing_reason
                                                      | _ -> None)
                                                    session.planned_workers))
                                            ~output_preview ();
                                          `Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                              ("status", `String "completed");
                                              ("trace_capability", `String (if Option.is_some run_result.raw_trace_run then "raw" else "summary_only"));
                                              ("resolved_runtime", `String "local");
                                              ("resolved_model", `String run_result.model_used);
                                              ( "output",
                                                `String run_result.output );
                                              ( "output_preview",
                                                `String output_preview );
                                              ( "tool_call_count",
                                                `Int run_result.tool_call_count );
                                              ( "tool_names",
                                                `List
                                                  (List.map
                                                     (fun name -> `String name)
                                                     run_result.tool_names) );
                                              ( "input_tokens",
                                                int_opt_to_json run_result.input_tokens );
                                              ( "output_tokens",
                                                int_opt_to_json run_result.output_tokens );
                                              ( "cost_usd",
                                                float_opt_to_json run_result.cost_usd );
                                            ]
                                      | Error err ->
                                          persist_worker_run_snapshot env
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate" ~wait_mode
                                            ~status:`Failed
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ~trace_capability:"summary_only" ();
                                          append_delegate_event env ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:"summary_only"
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err ();
                                          `Assoc [ ("error", `String err) ]
                                    in
                                    (match wait_mode with
                                    | Team_session_types.Wait_blocking ->
                                        Some (run_delegate ())
                                    | Team_session_types.Wait_background ->
                                        let sw_bg =
                                          Option.value ~default:ctx.sw
                                            (Eio_context.get_switch_opt ())
                                        in
                                        append_delegate_requested_event env
                                          ~worker_run_id ~worker_name
                                          ~delegate_prompt;
                                        Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                            ignore (run_delegate ()));
                                        Some
                                          (`Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("status", `String "accepted");
                                              ("wait_mode", `String "background");
                                            ])))))
                      in
                      let delegate_error =
                        match delegate_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" ->
                                Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match delegate_error with
                      | Some e -> (false, json_error e)
                      | None ->
                      let vote_result_json =
                        match get_string_opt args "vote_topic" with
                        | None -> None
                        | Some vote_topic ->
                            let vote_options = get_string_list args "vote_options" in
                            if List.length vote_options < 2 then
                              Some
                                (`Assoc
                                  [
                                    ("error", `String "vote_options requires at least 2 items");
                                  ])
                            else
                              let required_votes = get_int args "vote_required_votes" 2 in
                              let vote_create_msg =
                                Room.vote_create ctx.config ~proposer:actor
                                  ~topic:vote_topic ~options:vote_options
                                  ~required_votes
                              in
                              let vote_id = extract_vote_id vote_create_msg in
                              Team_session_store.append_event ctx.config session_id
                                ~event_type:"team_vote_created"
                                ~detail:
                                  (`Assoc
                                    [
                                      ("actor", `String actor);
                                      ("topic", `String vote_topic);
                                      ("required_votes", `Int required_votes);
                                      ("options", `List (List.map (fun o -> `String o) vote_options));
                                      ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                      ("result", `String vote_create_msg);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                              let cast_json =
                                match (vote_id, get_string_opt args "vote_choice") with
                                | Some vid, Some choice ->
                                    let cast_msg =
                                      Room.vote_cast ctx.config ~agent_name:actor
                                        ~vote_id:vid ~choice
                                    in
                                    Team_session_store.append_event ctx.config session_id
                                      ~event_type:"team_vote_cast"
                                      ~detail:
                                        (`Assoc
                                          [
                                            ("actor", `String actor);
                                            ("vote_id", `String vid);
                                            ("choice", `String choice);
                                            ("result", `String cast_msg);
                                            ("ts_iso", `String (Types.now_iso ()));
                                          ]);
                                    Some (`Assoc [ ("vote_id", `String vid); ("choice", `String choice); ("result", `String cast_msg) ])
                                | _ -> None
                              in
                              Some
                                (`Assoc
                                  [
                                    ("created", `String vote_create_msg);
                                    ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                    ("cast", Option.fold ~none:`Null ~some:(fun j -> j) cast_json);
                                  ])
                      in
                      let vote_error =
                        match vote_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" -> Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match vote_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let run_json =
                            match get_string_opt args "run_task_id" with
                            | None -> None
                            | Some run_task_id ->
                                let run_agent = actor in
                                let init_json =
                                  match
                                    Run_eio.init ctx.config ~task_id:run_task_id
                                      ~agent_name:(Some run_agent)
                                  with
                                  | Ok run -> `Assoc [ ("status", `String "initialized"); ("run", Run_eio.run_record_to_json run) ]
                                  | Error e -> `Assoc [ ("status", `String "init_failed"); ("error", `String e) ]
                                in
                                let note_json =
                                  match get_string_opt args "run_note" with
                                  | None -> `Null
                                  | Some note -> (
                                      match Run_eio.append_log ctx.config ~task_id:run_task_id ~note with
                                      | Ok entry -> `Assoc [ ("status", `String "ok"); ("entry", Run_eio.log_entry_to_json entry) ]
                                      | Error e -> `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                let deliverable_json =
                                  match get_string_opt args "run_deliverable" with
                                  | None -> `Null
                                  | Some content -> (
                                      match
                                        Run_eio.set_deliverable ctx.config
                                          ~task_id:run_task_id ~content
                                      with
                                      | Ok run ->
                                          Team_session_store.append_event ctx.config
                                            session_id
                                            ~event_type:"team_run_deliverable"
                                            ~detail:
                                              (`Assoc
                                                [
                                                  ("actor", `String actor);
                                                  ("run_task_id", `String run_task_id);
                                                  ("deliverable_preview", `String (truncate_for_event content));
                                                  ("ts_iso", `String (Types.now_iso ()));
                                                ]);
                                          `Assoc [ ("status", `String "ok"); ("run", Run_eio.run_record_to_json run) ]
                                      | Error e ->
                                          `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                Some
                                  (`Assoc
                                    [
                                      ("task_id", `String run_task_id);
                                      ("init", init_json);
                                      ("note", note_json);
                                      ("deliverable", deliverable_json);
                                    ])
                          in
                          let response =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("turn", Option.value ~default:`Null turn_json);
                                ("spawn", Option.fold ~none:`Null ~some:(fun j -> j) spawn_result_json);
                                ("delegate", Option.fold ~none:`Null ~some:(fun j -> j) delegate_result_json);
                                ("vote", Option.fold ~none:`Null ~some:(fun j -> j) vote_result_json);
                                ("run", Option.fold ~none:`Null ~some:(fun j -> j) run_json);
                              ]
                          in
                          (true, json_ok [ ("result", response) ]))

let handle_finalize ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "finalize" in
          let _wait_timeout_sec = get_int args "wait_timeout_sec" 45 in
          let generate_report = get_bool args "generate_report" true in
          let generate_proof = get_bool args "generate_proof" true in
          let proof_level = parse_proof_level args in
          match
            Team_session_engine_eio.finalize_session ~config:ctx.config ~session_id
              ~final_status:Team_session_types.Interrupted ~reason
              ~generate_report
          with
          | None -> (false, json_error ("team session not found: " ^ session_id))
          | Some finalized_session ->
              let terminal_status =
                Team_session_types.status_to_string finalized_session.status
              in
              let status_json =
                Team_session_engine_eio.session_status_json ctx.config
                  finalized_session
              in
                  let report_json =
                    if generate_report then
                      match
                        Team_session_engine_eio.generate_report ~config:ctx.config
                          ~session_id ~force_regenerate:false
                      with
                      | Ok json ->
                          `Assoc [ ("status", `String "ok"); ("result", json) ]
                      | Error e ->
                          `Assoc
                            [ ("status", `String "error"); ("message", `String e) ]
                    else
                      `Null
                  in
                  let report_error =
                    match report_json with
                    | `Assoc fields -> (
                        match List.assoc_opt "status" fields with
                        | Some (`String "error") -> (
                            match List.assoc_opt "message" fields with
                            | Some (`String msg) -> Some msg
                            | _ -> Some "report generation failed")
                        | _ -> None)
                    | _ -> None
                  in
                  (match report_error with
                  | Some e -> (false, json_error e)
                  | None ->
                      let proof_json =
                        if generate_proof then
                          match
                            Team_session_engine_eio.prove_session
                              ~config:ctx.config ~session_id ~proof_level
                              ~generate_report_if_missing:generate_report
                          with
                          | Ok json ->
                              `Assoc [ ("status", `String "ok"); ("result", json) ]
                          | Error e ->
                              `Assoc
                                [
                                  ("status", `String "error");
                                  ("message", `String e);
                                ]
                        else
                          `Null
                      in
                      let proof_error =
                        match proof_json with
                        | `Assoc fields -> (
                            match List.assoc_opt "status" fields with
                            | Some (`String "error") -> (
                                match List.assoc_opt "message" fields with
                                | Some (`String msg) -> Some msg
                                | _ -> Some "proof generation failed")
                            | _ -> None)
                        | _ -> None
                      in
                      match proof_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let payload =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("terminal_status", `String terminal_status);
                                ("status", `String terminal_status);
                                ("status_detail", status_json);
                                ("report", report_json);
                                ("proof", proof_json);
                              ]
                          in
                          ( true,
                            json_ok
                              [
                                ("result", payload);
                              ] )))

let handle_events ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let event_types = get_string_list args "event_types" in
          let limit = get_int args "limit" 200 in
          let after_ts = get_float_opt args "after_ts" in
          (match
             Team_session_engine_eio.list_events ~config:ctx.config ~session_id
               ~event_types ~limit ~after_ts
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_prove ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let generate_report_if_missing =
            get_bool args "generate_report_if_missing" true
          in
          let proof_level = parse_proof_level args in
          (match
             Team_session_engine_eio.prove_session ~config:ctx.config ~session_id
               ~proof_level
               ~generate_report_if_missing
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_verify_trace ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let worker_run_id =
            match get_string_opt args "worker_run_id" with
            | Some id when String.trim id <> "" -> Some (String.trim id)
            | _ -> latest_worker_run_id ctx.config session_id
          in
          let verification_result meta_json worker_run_id =
            let worker_run_summary =
              `Assoc
                [
                  ("worker_run_id", `String worker_run_id);
                  ("worker_name", Yojson.Safe.Util.member "worker_name" meta_json);
                  ("status", Yojson.Safe.Util.member "status" meta_json);
                  ("mode", Yojson.Safe.Util.member "mode" meta_json);
                  ("wait_mode", Yojson.Safe.Util.member "wait_mode" meta_json);
                  ("success", Yojson.Safe.Util.member "success" meta_json);
                  ("execution_scope", Yojson.Safe.Util.member "execution_scope" meta_json);
                  ("requested_worker_class", Yojson.Safe.Util.member "requested_worker_class" meta_json);
                  ("requested_worker_size", Yojson.Safe.Util.member "requested_worker_size" meta_json);
                  ("resolved_runtime", Yojson.Safe.Util.member "resolved_runtime" meta_json);
                  ("resolved_model", Yojson.Safe.Util.member "resolved_model" meta_json);
                  ("routing_reason", Yojson.Safe.Util.member "routing_reason" meta_json);
                  ("tool_names", Yojson.Safe.Util.member "tool_names" meta_json);
                  ("tool_call_count", Yojson.Safe.Util.member "tool_call_count" meta_json);
                  ("output_preview", Yojson.Safe.Util.member "output_preview" meta_json);
                ]
            in
            let session_root = oas_trace_session_root ctx.config in
            match evidence_session_id_of_json meta_json with
            | Some evidence_session_id -> (
                match
                  Oas.Sessions.get_proof_bundle ~session_root
                    ~session_id:evidence_session_id (),
                  Oas.Conformance.run ~session_root
                    ~session_id:evidence_session_id ()
                with
                | Ok bundle, Ok report -> (
                    match bundle.latest_raw_trace_run with
                    | Some run_ref -> (
                        match
                          Oas.Sessions.get_raw_trace_records ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id (),
                          Oas.Sessions.get_raw_trace_summary ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id (),
                          Oas.Sessions.validate_raw_trace_run ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id ()
                        with
                        | Ok records, Ok summary, Ok validation ->
                            let verification =
                              verification_json ~records ~summary ~validation
                            in
                            ( true,
                              json_ok
                                [
                                  ( "result",
                                    `Assoc
                                      [
                                        ("worker_run_id", `String worker_run_id);
                                        ("trace_capability", `String "raw");
                                        ( "worker_run",
                                          Option.fold ~none:worker_run_summary
                                            ~some:Oas.Sessions.worker_run_to_yojson
                                            bundle.latest_worker_run );
                                        ( "trace_ref",
                                          Oas.Raw_trace.run_ref_to_yojson summary.run_ref );
                                        ("verification", verification);
                                        ( "session_conformance",
                                          Oas.Conformance.report_to_yojson report );
                                      ] );
                                ] )
                        | records_result, summary_result, validation_result ->
                            let detail =
                              match
                                records_result, summary_result,
                                validation_result
                              with
                              | Error err, _, _
                              | _, Error err, _
                              | _, _, Error err ->
                                  Oas.Error.to_string err
                              | _ -> "raw trace verification failed"
                            in
                            ( true,
                              json_ok
                                [
                                  ( "result",
                                    `Assoc
                                      [
                                        ("worker_run_id", `String worker_run_id);
                                        ("trace_capability", `String "summary_only");
                                        ("ok", `Bool false);
                                        ("error", `String detail);
                                        ( "worker_run",
                                          Option.fold ~none:worker_run_summary
                                            ~some:Oas.Sessions.worker_run_to_yojson
                                            bundle.latest_worker_run );
                                        ( "session_conformance",
                                          Oas.Conformance.report_to_yojson report );
                                      ] );
                                ] ))
                    | None ->
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "summary_only");
                                    ("ok", `Bool false);
                                    ( "error",
                                      `String
                                        "direct evidence proof bundle did not contain a raw trace run" );
                                    ( "worker_run",
                                      Option.fold ~none:worker_run_summary
                                        ~some:Oas.Sessions.worker_run_to_yojson
                                        bundle.latest_worker_run );
                                    ( "session_conformance",
                                      Oas.Conformance.report_to_yojson report );
                                  ] );
                            ] ))
                | bundle_result, conformance_result ->
                    let detail =
                      match bundle_result, conformance_result with
                      | Error err, _
                      | _, Error err ->
                          Oas.Error.to_string err
                      | _ -> "direct evidence verification failed"
                    in
                    ( true,
                      json_ok
                        [
                          ( "result",
                            `Assoc
                              [
                                ("worker_run_id", `String worker_run_id);
                                ("trace_capability", `String "summary_only");
                                ("ok", `Bool false);
                                ("error", `String detail);
                                ("worker_run", worker_run_summary);
                              ] );
                        ] ))
            | None -> (
                match trace_run_locator_of_json meta_json with
                | Some locator ->
                    let trace_session_id =
                      Option.value ~default:session_id locator.session_id
                    in
                    (match
                       Oas.Sessions.get_raw_trace_records ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id (),
                       Oas.Sessions.get_raw_trace_summary ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id (),
                       Oas.Sessions.validate_raw_trace_run ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id ()
                     with
                    | Ok records, Ok summary, Ok validation ->
                        let verification =
                          verification_json ~records ~summary ~validation
                        in
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "raw");
                                    ("worker_run", worker_run_summary);
                                    ( "trace_ref",
                                      Oas.Raw_trace.run_ref_to_yojson summary.run_ref );
                                    ("verification", verification);
                                  ] );
                            ] )
                    | records_result, summary_result, validation_result ->
                        let detail =
                          match
                            records_result, summary_result, validation_result
                          with
                          | Error err, _, _
                          | _, Error err, _
                          | _, _, Error err ->
                              Oas.Error.to_string err
                          | _ -> "raw trace verification failed"
                        in
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "summary_only");
                                    ("ok", `Bool false);
                                    ("error", `String detail);
                                    ("worker_run", worker_run_summary);
                                  ] );
                            ] ))
                | None ->
                    ( true,
                      json_ok
                        [
                          ( "result",
                            `Assoc
                              [
                                ("worker_run_id", `String worker_run_id);
                                ("trace_capability", `String "summary_only");
                                ("ok", `Bool false);
                                ( "error",
                                  `String
                                    "raw trace reference missing for worker run" );
                                ("worker_run", worker_run_summary);
                              ] );
                        ] ))
          in
          match worker_run_id with
          | None -> (false, json_error "no worker run found for session")
          | Some worker_run_id -> (
              match load_worker_run_meta ctx.config session_id worker_run_id with
              | Error e -> (false, json_error e)
              | Ok meta_json -> verification_result meta_json worker_run_id))

