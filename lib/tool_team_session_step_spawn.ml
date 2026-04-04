(** Tool_team_session_step_spawn — spawn pipeline orchestrator for team session steps.

    Heavy lifting is in [Tool_team_session_step_spawn_impl].
    This module provides the single public entrypoint [execute_spawn_pipeline]. *)

include Tool_team_session_step_types

(** Execute the spawn pipeline: plan -> ensure actors -> execute -> summarize.
    Returns [Some json] with results or error, or [None] if no spawns. *)
let execute_spawn_pipeline
    (env : _ Tool_team_session_step_exec.step_env)
    prepared_spawns_result
    =
  let deps = env.deps in
  let ctx = env.ctx in
  let session_id = env.session_id in
  let wait_mode = env.wait_mode in
  let fail_all_prepared =
    Tool_team_session_step_exec.fail_all_prepared env
  in
  match prepared_spawns_result with
  | Error msg -> Some (`Assoc [ ("error", `String msg) ])
  | Ok [] -> None
  | Ok prepared_spawns ->
      (* Phase 1: register planned workers *)
      let planned_workers =
        List.map
          (fun prepared ->
            deps.planned_worker_of_spec ?runtime_actor:prepared.runtime_actor_name
              ?runtime_binding_ref:prepared.runtime_binding_ref
              prepared.spec)
          prepared_spawns
      in
      (match
         deps.register_planned_workers ctx.config session_id planned_workers
       with
      | Error msg ->
          fail_all_prepared ~include_worker_run_id:false prepared_spawns
            ~error:msg;
          Some (`Assoc [ ("error", `String msg) ])
      | Ok () -> (
          (* Phase 2: check process manager *)
          match ctx.proc_mgr with
          | None ->
              let msg =
                "process manager unavailable for team step spawn"
              in
              fail_all_prepared prepared_spawns ~error:msg;
              Some (`Assoc [ ("error", `String msg) ])
          | Some _pm ->
              (* Phase 3: materialize executions *)
              let prepared_executions =
                List.map
                  (Tool_team_session_step_exec.materialize_prepared_execution env)
                  prepared_spawns
              in
              let prepared_spawns_for_actors =
                List.map
                  (fun (execution : prepared_execution) -> execution.prepared)
                  prepared_executions
              in
              (* Phase 4: build docker specs and preflight *)
              let docker_specs =
                Tool_team_session_step_spawn_impl.build_docker_specs
                  ~base_path:ctx.config.base_path ~session_id
                  prepared_executions
              in
              (match
                 Worker_runtime.preflight_spawn_batch
                   ?clock_opt:(Some ctx.clock) docker_specs
               with
              | Error msg ->
                  Tool_team_session_step_spawn_impl
                  .fail_all_prepared_executions env prepared_executions
                    ~error:msg;
                  Some (`Assoc [ ("error", `String msg) ])
              | Ok () -> (
                  (* Phase 5: ensure session actors *)
                  match
                    Tool_team_session_step_spawn_impl.ensure_all_actors
                      ~ensure_session_actor:deps.ensure_session_actor
                      ~config:ctx.config ~session_id
                      prepared_spawns_for_actors
                  with
                  | Error msg ->
                      Tool_team_session_step_spawn_impl
                      .fail_all_prepared_executions env prepared_executions
                        ~error:msg;
                      Some (`Assoc [ ("error", `String msg) ])
                  | Ok () -> (
                      (* Phase 6: dispatch by wait mode *)
                      match wait_mode with
                      | Team_session_types.Wait_background ->
                          Tool_team_session_step_spawn_run.dispatch_background
                            env prepared_executions
                      | Team_session_types.Wait_blocking ->
                          Tool_team_session_step_spawn_run.dispatch_blocking
                            env prepared_executions)))))
