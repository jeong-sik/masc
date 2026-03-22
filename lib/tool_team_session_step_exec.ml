(** Tool_team_session_step_exec — extracted helper functions for step execution.

    Contains event-appending helpers, runtime management, and spawn preparation
    that were previously nested inside [handle_step]. *)

include Tool_team_session_step_types

(** Shared environment for step helper functions.
    Bundles the closed-over variables from [handle_step]. *)
type 'a step_env = {
  deps : step_deps;
  ctx : 'a context;
  session_id : string;
  actor : string;
  wait_mode : Team_session_types.wait_mode;
}

let append_spawn_event (env : _ step_env) ?worker_run_id ?spawn_agent ?runtime_actor ?spawn_role
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
        ("routing_confidence", env.deps.float_opt_to_json routing_confidence);
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
        ("exit_code", env.deps.int_opt_to_json exit_code);
        ("elapsed_ms", env.deps.int_opt_to_json elapsed_ms);
        ( "output_preview",
          Option.fold ~none:`Null ~some:(fun s -> `String s)
            output_preview );
        ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
        ("ts_iso", `String (Types.now_iso ()));
      ]
  in
  Team_session_store.append_event env.ctx.config env.session_id
    ~event_type:"team_step_spawn" ~detail

let append_delegate_event (env : _ step_env) ~worker_run_id ~worker_name ~delegate_prompt ~success
    ?execution_scope ?wait_mode ?trace_capability
    ?resolved_runtime ?resolved_model ?routing_reason
    ?tool_names ?tool_call_count ?output_preview ?error () =
  Team_session_store.append_event env.ctx.config env.session_id
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

let append_spawn_requested_event (env : _ step_env) ~worker_run_id prepared =
  Team_session_store.append_event env.ctx.config env.session_id
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
          ("worker_backend", if env.deps.is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
          ("wait_mode", `String (Team_session_types.wait_mode_to_string env.wait_mode));
          ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
          ("resolved_model", `String prepared.runtime_model_label);
          ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
          ("ts_iso", `String (Types.now_iso ()));
        ])

let append_delegate_requested_event (env : _ step_env) ~worker_run_id ~worker_name ~delegate_prompt =
  Team_session_store.append_event env.ctx.config env.session_id
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

let persist_worker_run_snapshot (env : _ step_env) ~worker_run_id ~worker_name
    ~mode ~wait_mode ?execution_scope ?tool_names ?tool_call_count
    ?requested_worker_class ?requested_worker_size
    ?resolved_runtime ?resolved_model ?routing_reason
    ~status
    ~success ?output_preview ?error ?trace_capability ?trace_ref
    ?trace_summary ?trace_validation ?evidence_session_id
    () =
  let checkpoint_path =
    Team_session_store.worker_container_checkpoint_path env.ctx.config
      env.session_id worker_name
  in
  let oas_evidence =
    Option.bind evidence_session_id (fun evidence_session_id ->
        env.deps.oas_worker_evidence_payload ~config:env.ctx.config
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
    | Some worker -> env.deps.oas_worker_status_to_json worker.status
    | None -> env.deps.worker_run_status_to_json status
  in
  let trace_capability =
    match trace_capability with
    | _ when Option.is_some oas_worker ->
        Option.value ~default:"summary_only"
          (Option.map
             (fun worker ->
               env.deps.oas_trace_capability_to_string
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
            Some (env.deps.truncate_for_event final_text)
        | _ -> output_preview)
    | None -> output_preview
  in
  if Room_utils.path_exists env.ctx.config checkpoint_path then
    Team_session_store.save_worker_run_checkpoint_text env.ctx.config
      env.session_id worker_run_id
      (Team_session_store.read_text_file checkpoint_path);
  Team_session_store.save_worker_run_meta_json env.ctx.config env.session_id
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
        ("trace_ref", Option.fold ~none:`Null ~some:env.deps.raw_trace_run_ref_to_json effective_trace_ref);
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

let release_prepared_runtime (prepared : prepared_spawn) ~success
    ?error ?latency_ms () =
  match prepared.runtime_lease with
  | Some lease ->
      Local_runtime_pool.release lease ~success ?error ?latency_ms ()
  | None -> ()

let release_all_prepared prepareds ~error =
  List.iter
    (fun prepared ->
      release_prepared_runtime prepared ~success:false ~error ())
    prepareds

let fail_all_prepared (env : _ step_env) ?(include_worker_run_id = true)
    prepared_spawns ~error =
  List.iter
    (fun (prepared : prepared_spawn) ->
      release_prepared_runtime prepared ~success:false ~error ();
      append_spawn_event env
        ?worker_run_id:
          (if include_worker_run_id then Some prepared.worker_run_id else None)
        ~spawn_agent:prepared.spec.spawn_agent
        ?runtime_actor:prepared.runtime_actor_name
        ?spawn_role:prepared.spec.spawn_role
        ?spawn_model:prepared.spec.spawn_model
        ?execution_scope:
          (env.deps.effective_execution_scope_of_spec prepared.spec)
        ?worker_class:prepared.spec.worker_class
        ?worker_size:(env.deps.worker_size_of_spec prepared.spec)
        ?worker_backend:
          (if env.deps.is_local_spawn_agent prepared.spec.spawn_agent then
             Some "local"
           else None)
        ?parent_actor:prepared.spec.parent_actor
        ?capsule_mode:prepared.spec.capsule_mode
        ?runtime_pool:prepared.spec.runtime_pool
        ?lane_id:prepared.spec.lane_id
        ?controller_level:
          (env.deps.inferred_controller_level_of_spec prepared.spec)
        ?control_domain:prepared.spec.control_domain
        ?supervisor_actor:prepared.spec.supervisor_actor
        ?model_tier:prepared.spec.model_tier
        ?task_profile:prepared.spec.task_profile
        ?risk_level:prepared.spec.risk_level
        ?routing_confidence:prepared.spec.routing_confidence
        ?routing_reason:prepared.spec.routing_reason
        ?assigned_runtime:prepared.assigned_runtime
        ?spawn_selection_note:prepared.spec.spawn_selection_note
        ~success:false ~error ())
    prepared_spawns

let prepare_spawn (env : _ step_env) (spec : spawn_spec) =
  let runtime_actor_name =
    if env.deps.is_local_spawn_agent spec.spawn_agent then
      Some
        (env.deps.derived_local_runtime_actor ~session_id:env.session_id
           ~prompt:spec.spawn_prompt)
    else
      None
  in
  let runtime_result =
    if env.deps.is_local_spawn_agent spec.spawn_agent then
      let model_name =
        match spec.spawn_model with
        | Some model_name -> Some model_name
        | None ->
            let default_model =
              Model_spec.default_local_model_spec ()
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
                ( Local_runtime_pool.model_label_of_assignment
                    assignment,
                  Some assignment.lease,
                  Some assignment.runtime_id )
          | Error err -> Error err)
    else
      let default_spec = Model_spec.default_local_model_spec () in
      Ok (Model_spec.label_of_model_spec default_spec, None, None)
  in
  match runtime_result with
  | Error e -> Error (spec, runtime_actor_name, e)
  | Ok (runtime_model_label, runtime_lease, assigned_runtime) ->
      Ok
        {
          worker_run_id = env.deps.make_worker_run_id ();
          spec;
          runtime_actor_name;
          runtime_model_label;
          runtime_lease;
          assigned_runtime;
        }
