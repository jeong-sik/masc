(** Tool_team_session_step_spawn_run — spawn execution and dispatch.

    Contains [execute_single_spawn], [dispatch_background], [dispatch_blocking],
    and their helpers [handle_unexpected_failure] and [process_spawn_result]. *)

include Tool_team_session_step_types

(** Handle an unexpected exception during spawn execution.
    Logs error, releases runtime, persists snapshot, emits events,
    reconciles failed actor, returns failure JSON. *)
let handle_unexpected_failure (env : _ Tool_team_session_step_exec.step_env)
    (execution : prepared_execution) ~index ~elapsed_ms error =
  let deps = env.deps in
  let ctx = env.ctx in
  let session_id = env.session_id in
  let wait_mode = env.wait_mode in
  let prepared = execution.prepared in
  let worker_name =
    Option.value
      ~default:(Printf.sprintf "spawn-%d-%s" index prepared.worker_run_id)
      prepared.runtime_actor_name
  in
  let execution_scope = Some execution.execution_scope in
  let worker_backend =
    Some (Worker_execution_backend.to_string execution.worker_backend)
  in
  let output_preview = deps.truncate_for_event error in
  Log.Spawn.error "spawn worker failed (worker_run_id=%s, agent=%s): %s"
    prepared.worker_run_id worker_name error;
  Tool_team_session_step_exec.release_prepared_runtime prepared ~success:false
    ~error ~latency_ms:elapsed_ms ();
  Tool_team_session_step_exec.persist_worker_run_snapshot env
    ~worker_run_id:prepared.worker_run_id ~worker_name ~mode:"spawn" ~wait_mode
    ~status:`Failed ?execution_scope
    ?requested_worker_class:prepared.spec.worker_class
    ?resolved_runtime:prepared.assigned_runtime
    ~resolved_model:prepared.runtime_model_label
    ?routing_reason:prepared.spec.routing_reason ~tool_names:[]
    ~tool_call_count:0 ~success:false ~output_preview
    ~evidence_session_id:
      (Worker_runtime.oas_worker_evidence_session_id
         ~worker_run_id:prepared.worker_run_id)
    ~trace_capability:"summary_only" ();
  Tool_team_session_step_exec.append_spawn_event env
    ~worker_run_id:prepared.worker_run_id
    ~spawn_agent:prepared.spec.spawn_agent
    ?runtime_actor:prepared.runtime_actor_name
    ?spawn_role:prepared.spec.spawn_role ?spawn_model:prepared.spec.spawn_model
    ?execution_scope ?worker_class:prepared.spec.worker_class ?worker_backend
    ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
    ~trace_capability:"summary_only"
    ?parent_actor:prepared.spec.parent_actor
    ?capsule_mode:prepared.spec.capsule_mode
    ?runtime_pool:prepared.spec.runtime_pool ?lane_id:prepared.spec.lane_id
    ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
    ?control_domain:prepared.spec.control_domain
    ?supervisor_actor:prepared.spec.supervisor_actor
    ?task_profile:prepared.spec.task_profile
    ?risk_level:prepared.spec.risk_level
    ?routing_confidence:prepared.spec.routing_confidence
    ?routing_reason:prepared.spec.routing_reason
    ?assigned_runtime:prepared.assigned_runtime
    ?spawn_selection_note:prepared.spec.spawn_selection_note ~tool_names:[]
    ~tool_call_count:0 ~success:false ~exit_code:1 ~elapsed_ms ~output_preview
    ~error ();
  (match prepared.runtime_actor_name with
  | Some worker_actor ->
      ignore
        (deps.reconcile_failed_spawn_actor ctx.config session_id worker_actor)
  | None -> ());
  Tool_team_session_step_spawn_impl.build_spawn_result_json
    ~worker_run_id:prepared.worker_run_id
    ~runtime_actor_name:prepared.runtime_actor_name
    ~spawn_role:prepared.spec.spawn_role ~execution_scope
    ~thinking_enabled:prepared.spec.thinking_enabled
    ~max_turns:prepared.spec.max_turns
    ~worker_class:prepared.spec.worker_class ~worker_backend ~wait_mode
    ~status:"failed" ~trace_capability:"summary_only"
    ~assigned_runtime:prepared.assigned_runtime
    ~resolved_model:prepared.runtime_model_label
    ~routing_reason:prepared.spec.routing_reason ~tool_call_count:0
    ~tool_names:[] ~success:false ~elapsed_ms ~output_preview ~exit_code:1
    ~error ~delivery_verdict_json:None ()

(** Process a completed spawn: release runtime, persist snapshot, emit events,
    record delivery verdict, add findings, reconcile actors, return result JSON. *)
let process_spawn_result (env : _ Tool_team_session_step_exec.step_env)
    (execution : prepared_execution) ~index
    (spawn_result : Spawn.spawn_result)
    (run_result : Worker_container_types.run_result option) =
  let deps = env.deps in
  let ctx = env.ctx in
  let session_id = env.session_id in
  let wait_mode = env.wait_mode in
  let prepared = execution.prepared in
  let worker_name =
    Option.value
      ~default:(Printf.sprintf "spawn-%d-%s" index prepared.worker_run_id)
      prepared.runtime_actor_name
  in
  let execution_scope = Some execution.execution_scope in
  let worker_backend =
    Some (Worker_execution_backend.to_string execution.worker_backend)
  in
  let output_preview = deps.truncate_for_event spawn_result.output in
  let (oas : Tool_team_session_step_spawn_impl.oas_run_fields) =
    Tool_team_session_step_spawn_impl.extract_oas_fields ~deps
      ~config:ctx.config ~session_id
      ~default_model_label:prepared.runtime_model_label run_result
  in
  let delivery_verdict_json =
    Tool_team_session_step_spawn_impl.verify_and_record_verdict
      ~config:ctx.config ~session_id ~worker_run_id:prepared.worker_run_id
      ~delivery_contract:execution.delivery_contract
      ~spawn_prompt:prepared.spec.spawn_prompt run_result
  in
  (match spawn_result.success with
  | true ->
      Tool_team_session_step_exec.release_prepared_runtime prepared ~success:true
        ~latency_ms:spawn_result.elapsed_ms ()
  | false ->
      Tool_team_session_step_exec.release_prepared_runtime prepared ~success:false
        ~error:spawn_result.output ~latency_ms:spawn_result.elapsed_ms ());
  Tool_team_session_step_exec.persist_worker_run_snapshot env
    ~worker_run_id:prepared.worker_run_id ~worker_name ~mode:"spawn" ~wait_mode
    ~status:(if spawn_result.success then `Completed else `Failed)
    ?execution_scope
    ?requested_worker_class:prepared.spec.worker_class
    ?resolved_runtime:prepared.assigned_runtime
    ~resolved_model:oas.resolved_model
    ?routing_reason:prepared.spec.routing_reason
    ~tool_names:oas.oas_tool_names
    ~tool_call_count:oas.oas_tool_call_count ~success:spawn_result.success
    ~output_preview
    ~evidence_session_id:
      (Worker_runtime.oas_worker_evidence_session_id
         ~worker_run_id:prepared.worker_run_id)
    ?trace_ref:oas.oas_trace_ref ?trace_summary:oas.trace_summary_json
    ?trace_validation:oas.trace_validation_json ?proof:oas.proof
    ~trace_capability:oas.trace_capability ();
  Tool_team_session_step_exec.append_spawn_event env
    ~worker_run_id:prepared.worker_run_id
    ~spawn_agent:prepared.spec.spawn_agent
    ?runtime_actor:prepared.runtime_actor_name
    ?spawn_role:prepared.spec.spawn_role ?spawn_model:prepared.spec.spawn_model
    ?execution_scope ?worker_class:prepared.spec.worker_class ?worker_backend
    ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
    ~trace_capability:oas.trace_capability
    ?parent_actor:prepared.spec.parent_actor
    ?capsule_mode:prepared.spec.capsule_mode
    ?runtime_pool:prepared.spec.runtime_pool ?lane_id:prepared.spec.lane_id
    ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
    ?control_domain:prepared.spec.control_domain
    ?supervisor_actor:prepared.spec.supervisor_actor
    ?task_profile:prepared.spec.task_profile
    ?risk_level:prepared.spec.risk_level
    ?routing_confidence:prepared.spec.routing_confidence
    ?routing_reason:prepared.spec.routing_reason
    ?assigned_runtime:prepared.assigned_runtime
    ?spawn_selection_note:prepared.spec.spawn_selection_note
    ~tool_names:oas.oas_tool_names ~tool_call_count:oas.oas_tool_call_count
    ~success:spawn_result.success ~exit_code:spawn_result.exit_code
    ~elapsed_ms:spawn_result.elapsed_ms ~output_preview ();
  Tool_team_session_step_spawn_impl.record_post_spawn_effects ~deps
    ~config:ctx.config ~session_id ~spawn_result
    ~runtime_actor_name:prepared.runtime_actor_name ~index;
  Tool_team_session_step_spawn_impl.build_spawn_result_json
    ~worker_run_id:prepared.worker_run_id
    ~runtime_actor_name:prepared.runtime_actor_name
    ~spawn_role:prepared.spec.spawn_role ~execution_scope
    ~thinking_enabled:prepared.spec.thinking_enabled
    ~max_turns:prepared.spec.max_turns
    ~worker_class:prepared.spec.worker_class ~worker_backend ~wait_mode
    ~status:(if spawn_result.success then "completed" else "failed")
    ~trace_capability:oas.trace_capability
    ~assigned_runtime:prepared.assigned_runtime
    ~resolved_model:oas.resolved_model
    ~routing_reason:prepared.spec.routing_reason
    ~tool_call_count:oas.oas_tool_call_count ~tool_names:oas.oas_tool_names
    ~success:spawn_result.success ~elapsed_ms:spawn_result.elapsed_ms
    ~output_preview ~delivery_verdict_json ()

(** Execute a single spawn: run the worker, then process result or handle exception. *)
let execute_single_spawn (env : _ Tool_team_session_step_exec.step_env)
    ~run_sw index (execution : prepared_execution) =
  let ctx = env.ctx in
  let session_id = env.session_id in
  let prepared = execution.prepared in
  let start_time = Time_compat.now () in
  let worker_name =
    Option.value
      ~default:(Printf.sprintf "spawn-%d-%s" index prepared.worker_run_id)
      prepared.runtime_actor_name
  in
  let execution_scope = Some execution.execution_scope in
  let delivery_contract = execution.delivery_contract in
  try
    let worker_result =
      Worker_runtime.run_worker ~sw:run_sw ?net:ctx.net
        ~backend:execution.worker_backend ~base_path:ctx.config.base_path
        ~worker_name ~model_label:prepared.runtime_model_label
        ~team_session_id:(Some session_id) ~room_config:(Some ctx.config)
        ?worker_class:prepared.spec.worker_class ?execution_scope
        ?thinking_enabled:prepared.spec.thinking_enabled
        ?allowed_shell_tools:(Some execution.local_shell_tool_names)
        ~max_turns:(Option.value ~default:10 prepared.spec.max_turns)
        ~worker_run_id:prepared.worker_run_id ?delivery_contract
        ~role:prepared.spec.spawn_role
        ~selection_note:prepared.spec.spawn_selection_note
        ~prompt:prepared.spec.spawn_prompt
        ~allowed_tools:execution.local_worker_tool_names
        ~timeout_sec:prepared.spec.spawn_timeout_seconds ()
    in
    let elapsed_ms =
      int_of_float ((Time_compat.now () -. start_time) *. 1000.0)
    in
    let spawn_result, run_result =
      match worker_result with
      | Ok run_result ->
          ( {
              Spawn.success = true;
              output = run_result.output;
              exit_code = 0;
              elapsed_ms;
              input_tokens = run_result.input_tokens;
              output_tokens = run_result.output_tokens;
              cache_creation_tokens = None;
              cache_read_tokens = None;
              cost_usd = run_result.cost_usd;
            },
            Some run_result )
      | Error e ->
          ( {
              Spawn.success = false;
              output = e;
              exit_code = 1;
              elapsed_ms;
              input_tokens = None;
              output_tokens = None;
              cache_creation_tokens = None;
              cache_read_tokens = None;
              cost_usd = None;
            },
            None )
    in
    process_spawn_result env execution ~index spawn_result run_result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let elapsed_ms =
        int_of_float ((Time_compat.now () -. start_time) *. 1000.0)
      in
      handle_unexpected_failure env execution ~index ~elapsed_ms
        (Printexc.to_string exn)

(** Dispatch spawns in background mode: fork fibers and return accepted JSON immediately. *)
let dispatch_background (env : _ Tool_team_session_step_exec.step_env)
    prepared_executions =
  let ctx = env.ctx in
  let sw_bg =
    Option.value ~default:ctx.sw (Eio_context.get_switch_opt ())
  in
  List.iteri
    (fun index (execution : prepared_execution) ->
      let prepared = execution.prepared in
      Tool_team_session_step_exec.append_spawn_requested_event_with_backend env
        ~worker_run_id:prepared.worker_run_id prepared
        ~worker_backend:(Some execution.worker_backend);
      Eio.Fiber.fork ~sw:sw_bg (fun () ->
          ignore (execute_single_spawn env ~run_sw:sw_bg index execution)))
    prepared_executions;
  let accepted =
    List.map Tool_team_session_step_spawn_impl.build_accepted_json
      prepared_executions
  in
  Some (Tool_team_session_step_spawn_impl.wrap_results accepted)

(** Dispatch spawns in blocking mode: run all concurrently and collect results. *)
let dispatch_blocking (env : _ Tool_team_session_step_exec.step_env)
    prepared_executions =
  let ctx = env.ctx in
  let results = Array.make (List.length prepared_executions) None in
  Eio.Fiber.all
    (List.mapi
       (fun index execution () ->
         results.(index) <-
           Some (execute_single_spawn env ~run_sw:ctx.sw index execution))
       prepared_executions);
  let spawn_results =
    results |> Array.to_list |> List.filter_map (fun item -> item)
  in
  Some (Tool_team_session_step_spawn_impl.wrap_results spawn_results)
