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

let delivery_contract_for_session config session_id =
  match Team_session_store.load_session config session_id with
  | Some session -> session.delivery_contract
  | None -> None

let delivery_contract_json_for_session config session_id =
  Option.map Team_session_types.delivery_contract_to_yojson
    (delivery_contract_for_session config session_id)

let latest_delivery_verdict_for_session config session_id =
  match Team_session_store.load_session config session_id with
  | Some session -> session.latest_delivery_verdict
  | None -> None

let latest_delivery_verdict_json_for_session config session_id =
  Option.map Team_session_types.delivery_verdict_to_yojson
    (latest_delivery_verdict_for_session config session_id)

let local_worker_tool_names_of_scope scope =
  Team_session_worker_run_meta.supported_local_worker_tool_names_for_scope
    (Some scope)

let local_shell_tool_names_of_scope = function
  | Team_session_types.Observe_only ->
      [ "file_read"; "shell_exec" ]
  | _ ->
      [ "file_read"; "file_write"; "shell_exec" ]

let delivery_verdict_of_verification ~session_id ~worker_run_id
    ~(contract : Team_session_types.delivery_contract)
    (outcome : Worker_verification.verification_outcome) :
    Team_session_types.delivery_verdict =
  let shared_evidence_refs =
    Team_session_types.dedup_strings
      (contract.evidence_refs
      @ [ "team-session:" ^ session_id; "worker-run:" ^ worker_run_id ])
  in
  let build ~status ~summary ?repair_directive () =
    {
      Team_session_types.contract_id = contract.contract_id;
      status;
      summary;
      evaluator = "verifier_oas";
      evaluator_role = contract.evaluator_role;
      evaluator_cascade = contract.evaluator_cascade;
      repair_directive;
      evidence_refs = shared_evidence_refs;
      generated_at_iso = Types.now_iso ();
    }
  in
  match outcome with
  | Worker_verification.Verified { verifier_verdict; _ } -> (
      match verifier_verdict with
      | Verifier_oas.Pass ->
          build ~status:Team_session_types.Delivery_pass
            ~summary:
              "Verifier accepted the worker output against the current delivery contract."
            ()
      | Verifier_oas.Warn reason ->
          build ~status:Team_session_types.Delivery_repair ~summary:reason
            ~repair_directive:reason ()
      | Verifier_oas.Fail reason ->
          build ~status:Team_session_types.Delivery_fail ~summary:reason
            ~repair_directive:reason ())
  | Worker_verification.Unverified { reason; verifier_verdict; _ } -> (
      match verifier_verdict with
      | Some (Verifier_oas.Warn detail) ->
          build ~status:Team_session_types.Delivery_repair ~summary:reason
            ~repair_directive:detail ()
      | Some (Verifier_oas.Fail detail) ->
          build ~status:Team_session_types.Delivery_fail ~summary:reason
            ~repair_directive:detail ()
      | Some Verifier_oas.Pass ->
          build ~status:Team_session_types.Delivery_fail ~summary:reason
            ()
      | None ->
          build ~status:Team_session_types.Delivery_repair ~summary:reason
            ~repair_directive:
              "Verifier could not produce a stable verdict. Re-run or inspect the captured evidence."
            ())

let record_delivery_verdict_for_worker_run ~(config : Room.config)
    ~(session_id : string) ~(worker_run_id : string)
    (outcome : Worker_verification.verification_outcome) : unit =
  match delivery_contract_for_session config session_id with
  | None -> ()
  | Some contract ->
      let verdict =
        delivery_verdict_of_verification ~session_id ~worker_run_id ~contract
          outcome
      in
      ignore
        (Team_session_store.update_session config session_id (fun session ->
             {
               session with
               latest_delivery_verdict = Some verdict;
               updated_at_iso = Types.now_iso ();
             }));
      Team_session_store.append_event config session_id
        ~event_type:"delivery_contract_verdict"
        ~detail:
          (`Assoc
            [
              ("contract_id", `String contract.contract_id);
              ("worker_run_id", `String worker_run_id);
              ( "status",
                `String
                  (Team_session_types.delivery_verdict_status_to_string
                     verdict.status) );
              ("summary", `String verdict.summary);
              ( "repair_directive",
                Option.fold ~none:`Null ~some:(fun value -> `String value)
                  verdict.repair_directive );
              ("evaluator", `String verdict.evaluator);
              ("evaluator_cascade", `String verdict.evaluator_cascade);
              ("generated_at_iso", `String verdict.generated_at_iso);
            ])

let append_spawn_event (env : _ step_env) ?worker_run_id ?spawn_agent ?runtime_actor ?spawn_role
    ?spawn_model ?execution_scope ?worker_class
    ?worker_backend ?wait_mode ?trace_capability
    ?parent_actor ?capsule_mode
    ?runtime_pool ?lane_id ?controller_level ?control_domain
    ?supervisor_actor ?task_profile ?risk_level
    ?routing_confidence ?routing_reason ?assigned_runtime
    ?spawn_selection_note ?tool_names ?tool_call_count ~success
    ?exit_code
    ?elapsed_ms ?output_preview ?error () =
  let _ = spawn_agent and _ = spawn_model in
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

let rec append_spawn_requested_event (env : _ step_env) ~worker_run_id prepared =
  append_spawn_requested_event_with_backend env ~worker_run_id prepared
    ~worker_backend:None

and append_spawn_requested_event_with_backend (env : _ step_env) ~worker_run_id
    prepared ~worker_backend =
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
          ( "worker_backend",
            match worker_backend with
            | Some backend ->
                `String (Worker_execution_backend.to_string backend)
            | None ->
                if env.deps.is_local_spawn_agent prepared.spec.spawn_agent then
                  `String "local"
                else `Null );
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

let append_delegate_denied_event (env : _ step_env) ~worker_name ~delegate_prompt
    ~blocked_reason ~guidance ~(readiness : Yojson.Safe.t) =
  Team_session_store.append_event env.ctx.config env.session_id
    ~event_type:"team_step_delegate_denied"
    ~detail:
      (`Assoc
        [
          ("actor", `String env.actor);
          ("target_agent", `String worker_name);
          ("delegate_prompt", `String delegate_prompt);
          ("worker_backend", `String "local");
          ("blocked_reason", `String blocked_reason);
          ("guidance", `String guidance);
          ("readiness", readiness);
          ("wait_mode", `String (Team_session_types.wait_mode_to_string env.wait_mode));
          ("ts_iso", `String (Types.now_iso ()));
        ])

let persist_worker_run_snapshot (env : _ step_env) ~worker_run_id ~worker_name
    ~mode ~wait_mode ?execution_scope ?tool_names ?tool_call_count
    ?requested_worker_class
    ?resolved_runtime ?resolved_model ?routing_reason
    ~status
    ~success ?output_preview ?error ?trace_capability ?trace_ref
    ?trace_summary ?trace_validation ?evidence_session_id
    ?proof
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
  let effective_trace_capability =
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
  Team_session_worker_run_meta.persist ~config:env.ctx.config
    ~session_id:env.session_id ~worker_run_id ~worker_name ~mode ~wait_mode
    ?execution_scope ?requested_worker_class ?resolved_runtime
    ?resolved_model:effective_resolved_model ?routing_reason
    ~tool_names:effective_tool_names ?tool_call_count ~status:effective_status
    ~success ?output_preview:effective_output_preview ?error:effective_error
    ~trace_capability:effective_trace_capability
    ?trace_ref:effective_trace_ref ?trace_summary:effective_trace_summary
    ?trace_validation:effective_trace_validation ?evidence_session_id
    ?oas_evidence
    ?final_text:
      (Option.bind oas_worker (fun worker -> worker.Oas.Sessions.final_text))
    ?stop_reason:
      (Option.bind oas_worker (fun worker -> worker.Oas.Sessions.stop_reason))
    ?failure_reason:
      (Option.bind oas_worker (fun worker ->
           worker.Oas.Sessions.failure_reason))
    ?proof ()

let release_prepared_runtime (prepared : prepared_spawn) ~success
    ?error ?latency_ms () =
  if prepared.lease_released then ()
  else (
    prepared.lease_released <- true;
    match prepared.runtime_lease with
    | Some lease ->
        Local_runtime_pool.release lease ~success ?error ?latency_ms ()
    | None -> ())

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
            let _label, model_id =
              Oas_model_resolve.default_local_model_label_and_id ()
            in
            Some model_id
      in
      match model_name with
      | None -> Error "local worker model resolution failed"
      | Some model_name ->
          let runtime_pool =
            match spec.runtime_pool with
            | Some pool ->
                let trimmed = String.trim pool in
                if trimmed = "" then None else Some trimmed
            | None -> None
          in
          let use_oas_balancing =
            match runtime_pool with
            | None -> true
            | Some pool ->
                String.equal pool Local_runtime_pool.default_pool_label
                || String.equal pool "default"
          in
          if use_oas_balancing then
            let base_url = Llm_provider.Provider_registry.next_llama_endpoint () in
            Ok
              ( Printf.sprintf "custom:%s@%s" model_name base_url,
                None,
                Some (Local_runtime_pool.runtime_id_of_base_url base_url) )
          else (
            match
              Local_runtime_pool.acquire
                ?preferred_pool:spec.runtime_pool
                ~model_name:(Some model_name) ()
            with
            | Ok assignment ->
                Ok
                  ( Printf.sprintf "custom:%s@%s" assignment.model_name
                      assignment.base_url,
                    Some assignment.lease,
                    Some assignment.runtime_id )
            | Error err -> Error err)
    else
      let label, _model_id = Oas_model_resolve.default_local_model_label_and_id () in
      Ok (label, None, None)
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
          lease_released = false;
        }

let materialize_prepared_execution (env : _ step_env) (prepared : prepared_spawn)
    : prepared_execution =
  let execution_scope =
    match env.deps.effective_execution_scope_of_spec prepared.spec with
    | Some scope -> scope
    | None ->
        Team_session_types.effective_execution_scope
          ~worker_class:prepared.spec.worker_class
          prepared.spec.execution_scope
  in
  {
    prepared;
    execution_scope;
    local_worker_tool_names = local_worker_tool_names_of_scope execution_scope;
    local_shell_tool_names = local_shell_tool_names_of_scope execution_scope;
    delivery_contract =
      delivery_contract_for_session env.ctx.config env.session_id;
    worker_backend =
      Worker_runtime_config.backend_for_scope execution_scope;
  }
