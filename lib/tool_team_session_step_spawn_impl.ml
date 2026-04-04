(** Tool_team_session_step_spawn_impl — preparation helpers for the spawn pipeline.

    Contains pre-execution helpers: failure propagation, actor checks, docker specs,
    and JSON assembly.  Execution logic lives in [Tool_team_session_step_spawn_run]. *)

include Tool_team_session_step_types

(** Fail all prepared executions: emit requested+spawn events and release runtimes. *)
let fail_all_prepared_executions (env : _ Tool_team_session_step_exec.step_env)
    prepared_executions ~error =
  let deps = env.deps in
  let append_spawn_requested_event_with_backend =
    Tool_team_session_step_exec.append_spawn_requested_event_with_backend env
  in
  let release_prepared_runtime =
    Tool_team_session_step_exec.release_prepared_runtime
  in
  let append_spawn_event = Tool_team_session_step_exec.append_spawn_event env in
  List.iter
    (fun (execution : prepared_execution) ->
      let prepared = execution.prepared in
      append_spawn_requested_event_with_backend
        ~worker_run_id:prepared.worker_run_id prepared
        ~worker_backend:(Some execution.worker_backend);
      release_prepared_runtime prepared ~success:false ~error ();
      append_spawn_event ~worker_run_id:prepared.worker_run_id
        ~spawn_agent:prepared.spec.spawn_agent
        ?runtime_actor:prepared.runtime_actor_name
        ?spawn_role:prepared.spec.spawn_role
        ?runtime_binding_ref:prepared.runtime_binding_ref
        ~artifact_scope:prepared.spec.artifact_scope
        ~execution_scope:execution.execution_scope
        ?worker_class:prepared.spec.worker_class
        ~worker_backend:
          (Worker_execution_backend.to_string execution.worker_backend)
        ?parent_actor:prepared.spec.parent_actor
        ?capsule_mode:prepared.spec.capsule_mode
        ?runtime_pool:prepared.spec.runtime_pool
        ?lane_id:prepared.spec.lane_id
        ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
        ?control_domain:prepared.spec.control_domain
        ?supervisor_actor:prepared.spec.supervisor_actor
        ?task_profile:prepared.spec.task_profile
        ?risk_level:prepared.spec.risk_level
        ?routing_confidence:prepared.spec.routing_confidence
        ?routing_reason:prepared.spec.routing_reason
        ?assigned_runtime:prepared.assigned_runtime
        ?spawn_selection_note:prepared.spec.spawn_selection_note
        ~success:false ~error ())
    prepared_executions

(** Ensure all prepared spawns have their session actors registered. *)
let ensure_all_actors ~ensure_session_actor ~config ~session_id prepared_spawns =
  let rec go = function
    | [] -> Ok ()
    | prepared :: rest -> (
        match prepared.runtime_actor_name with
        | None -> go rest
        | Some worker_actor -> (
            match ensure_session_actor config session_id worker_actor with
            | Ok () -> go rest
            | Error msg -> Error msg))
  in
  go prepared_spawns

(** Build Docker execution specs from prepared executions. *)
let build_docker_specs ~base_path ~session_id prepared_executions =
  prepared_executions
  |> List.mapi (fun i execution -> (i, execution))
  |> List.filter_map (fun (i, (execution : prepared_execution)) ->
         match execution.worker_backend with
         | Worker_execution_backend.Local -> None
         | Worker_execution_backend.Docker ->
             let prepared = execution.prepared in
             let worker_name =
               Option.value
                 ~default:
                   (Printf.sprintf "spawn-%d-%s" i prepared.worker_run_id)
                 prepared.runtime_actor_name
             in
             Some
               (Worker_runtime.build_execution_spec ~base_path ~worker_name
                  ~model_label:prepared.runtime_model_label
                  ~team_session_id:(Some session_id)
                  ?worker_class:prepared.spec.worker_class
                  ~execution_scope:execution.execution_scope
                  ?thinking_enabled:prepared.spec.thinking_enabled
                  ?allowed_shell_tools:(Some execution.local_shell_tool_names)
                  ~max_turns:
                    (Option.value ~default:10 prepared.spec.max_turns)
                  ~worker_run_id:prepared.worker_run_id
                  ?delivery_contract:execution.delivery_contract
                  ~role:prepared.spec.spawn_role
                  ~selection_note:prepared.spec.spawn_selection_note
                  ~prompt:prepared.spec.spawn_prompt
                  ~allowed_tools:execution.local_worker_tool_names
                  ~timeout_sec:prepared.spec.spawn_timeout_seconds ()))

(** Extracted OAS fields from a worker run result. *)
type oas_run_fields = {
  oas_trace_ref : Agent_sdk.Raw_trace.run_ref option;
  oas_tool_names : string list;
  oas_tool_call_count : int;
  resolved_model : string;
  trace_summary_json : Yojson.Safe.t option;
  trace_validation_json : Yojson.Safe.t option;
  proof : Agent_sdk.Cdal_proof.t option;
  trace_capability : string;
}

let proof_ref_of_proof = function
  | None -> None
  | Some (proof : Agent_sdk.Cdal_proof.t) -> (
      match Repo_synthesis_benchmark.validate_run_id proof.run_id with
      | Ok run_id ->
          Some (Agent_sdk.Proof_store.make_ref ~run_id ~subpath:"manifest.json")
      | Error msg ->
          Log.Misc.warn
            "team_session_step_spawn: dropping invalid proof_run_id %S: %s"
            proof.run_id msg;
          None)

(** Extract OAS-related fields from a worker run result. *)
let extract_oas_fields ~(deps : step_deps) ~config ~session_id
    ~default_model_label
    (run_result : Worker_container_types.run_result option) =
  let oas_trace_ref =
    Option.bind run_result (fun (r : Worker_container_types.run_result) ->
        r.raw_trace_run)
  in
  let oas_tool_names =
    Option.value ~default:[]
      (Option.map
         (fun (r : Worker_container_types.run_result) -> r.tool_names)
         run_result)
  in
  let oas_tool_call_count =
    Option.value ~default:0
      (Option.map
         (fun (r : Worker_container_types.run_result) -> r.tool_call_count)
         run_result)
  in
  let resolved_model =
    Option.value ~default:default_model_label
      (Option.map
         (fun (r : Worker_container_types.run_result) -> r.model_used)
         run_result)
  in
  let trace_summary_json, trace_validation_json =
    match oas_trace_ref with
    | Some run_ref -> (
        match
          deps.raw_trace_session_payloads ~config
            ~fallback_session_id:session_id run_ref
        with
        | Some pair -> (Some (fst pair), Some (snd pair))
        | None -> (None, None))
    | None -> (None, None)
  in
  let proof =
    Option.bind run_result (fun (r : Worker_container_types.run_result) ->
        r.proof)
  in
  let trace_capability =
    if Option.is_some oas_trace_ref then "raw" else "summary_only"
  in
  {
    oas_trace_ref;
    oas_tool_names;
    oas_tool_call_count;
    resolved_model;
    trace_summary_json;
    trace_validation_json;
    proof;
    trace_capability;
  }

(** Run verification and record delivery verdict. Returns verdict JSON. *)
let verify_and_record_verdict ~config ~session_id
    ~worker_run_id ~delivery_contract ~spawn_prompt
    (run_result : Worker_container_types.run_result option) =
  let verification_outcome =
    match run_result with
    | Some run_result ->
        let goal =
          match Team_session_store.load_session config session_id with
          | Some session -> session.goal
          | None -> spawn_prompt
        in
        Some
          (Worker_verification.verify_worker_result ?delivery_contract ~goal
             run_result)
    | None -> None
  in
  Option.iter
    (Tool_team_session_step_exec.record_delivery_verdict_for_worker_run ~config
       ~session_id ~worker_run_id)
    verification_outcome;
  Tool_team_session_step_exec.latest_delivery_verdict_json_for_session config
    session_id

(** Post-spawn side effects: auto-note turn, add finding, reconcile failed actor. *)
let record_post_spawn_effects ~(deps : step_deps) ~config ~session_id
    ~(spawn_result : Spawn.spawn_result) ~runtime_actor_name ~index =
  (match
     ( spawn_result.success,
       runtime_actor_name,
       deps.auto_note_message_of_spawn_output spawn_result.output )
   with
  | true, Some worker_actor, Some auto_note
    when
      not (deps.session_has_turn_for_actor config session_id worker_actor) ->
      ignore
        (deps.record_session_turn_json ~config ~session_id ~actor:worker_actor
           ~turn_kind:Team_session_types.Turn_note ~message:(Some auto_note)
           ~target_agent:None ~task_title:None ~task_description:None
           ~task_priority:3)
  | _ -> ());
  if spawn_result.success && String.length spawn_result.output > 0 then (
    let finding_preview =
      let len = String.length spawn_result.output in
      if len <= 200 then spawn_result.output
      else String.sub spawn_result.output 0 200
    in
    let finding_worker_name =
      Option.value
        ~default:(Printf.sprintf "spawn-%d" index)
        runtime_actor_name
    in
    Team_context.add_finding ~base_path:config.Room_utils.base_path
      ~team_session_id:session_id ~worker_name:finding_worker_name
      ~finding:finding_preview)
  else ();
  (match (spawn_result.success, runtime_actor_name) with
  | false, Some worker_actor ->
      ignore (deps.reconcile_failed_spawn_actor config session_id worker_actor)
  | _ -> ())

(** Build the result JSON for a single spawn worker. *)
let build_spawn_result_json ~worker_run_id ~runtime_actor_name ~spawn_role
    ~execution_scope ~thinking_enabled ~max_turns ~worker_class ~worker_backend
    ~wait_mode ~status ~trace_capability ~runtime_binding_ref ~assigned_runtime
    ?proof_ref
    ~routing_reason ~tool_call_count ~tool_names ~success ~elapsed_ms
    ~output_preview ?exit_code ?error
    ~(delivery_verdict_json : Yojson.Safe.t option) () =
  let opt_string key v =
    (key, Option.fold ~none:`Null ~some:(fun s -> `String s) v)
  in
  `Assoc
    ([
       ("worker_run_id", `String worker_run_id);
       opt_string "runtime_actor" runtime_actor_name;
       opt_string "spawn_role" spawn_role;
       ( "execution_scope",
         Option.fold ~none:`Null
           ~some:(fun scope ->
             `String (Team_session_types.execution_scope_to_string scope))
           execution_scope );
       ( "thinking_enabled",
         Option.fold ~none:`Null ~some:(fun v -> `Bool v) thinking_enabled );
       ( "max_turns",
         Option.fold ~none:`Null ~some:(fun n -> `Int n) max_turns );
       ( "worker_class",
         Option.fold ~none:`Null
           ~some:(fun kind ->
             `String (Team_session_types.worker_class_to_string kind))
           worker_class );
       opt_string "worker_backend" worker_backend;
       ( "wait_mode",
         `String (Team_session_types.wait_mode_to_string wait_mode) );
       ("status", `String status);
       ("trace_capability", `String trace_capability);
       opt_string "runtime_binding_ref" runtime_binding_ref;
       opt_string "resolved_runtime" assigned_runtime;
       opt_string "proof_ref" proof_ref;
       opt_string "routing_reason" routing_reason;
       ("tool_call_count", `Int tool_call_count);
       ("tool_names", `List (List.map (fun name -> `String name) tool_names));
       ("success", `Bool success);
       ("elapsed_ms", `Int elapsed_ms);
       ("output_preview", `String output_preview);
     ]
    @ (match error with Some e -> [ ("error", `String e) ] | None -> [])
    @ (match exit_code with
       | Some code -> [ ("exit_code", `Int code) ]
       | None -> [])
    @ [ ("delivery_verdict",
          Option.value ~default:`Null delivery_verdict_json) ])

(** Build accepted-status JSON for a background-mode spawn. *)
let build_accepted_json (execution : prepared_execution) =
  let prepared = execution.prepared in
  `Assoc
    [
      ("worker_run_id", `String prepared.worker_run_id);
      ("status", `String "accepted");
      ("wait_mode", `String "background");
      ( "runtime_actor",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          prepared.runtime_actor_name );
      ( "spawn_role",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          prepared.spec.spawn_role );
      ( "worker_class",
        Option.fold ~none:`Null
          ~some:(fun kind ->
            `String (Team_session_types.worker_class_to_string kind))
          prepared.spec.worker_class );
      ( "worker_backend",
        `String (Worker_execution_backend.to_string execution.worker_backend) );
      ( "runtime_binding_ref",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          prepared.runtime_binding_ref );
      ( "resolved_runtime",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          prepared.assigned_runtime );
      ( "routing_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          prepared.spec.routing_reason );
      ("ready", `Bool false);
    ]

(** Wrap a list of JSON results: single result unwrapped, multiple in batch envelope. *)
let wrap_results results =
  match results with
  | [ single ] -> single
  | _ ->
      `Assoc
        [
          ("mode", `String "batch");
          ("count", `Int (List.length results));
          ("results", `List results);
        ]
