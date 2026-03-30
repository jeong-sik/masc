(** Tool_team_session_step_spawn — spawn pipeline for team session steps.
    Extracted from tool_team_session_step.ml for modularity. *)

include Tool_team_session_step_types

(** Execute the spawn pipeline: plan → ensure actors → execute → summarize.
    Returns [Some json] with results or error, or [None] if no spawns. *)
let execute_spawn_pipeline
    (env : _ Tool_team_session_step_exec.step_env)
    prepared_spawns_result
    =
  let deps = env.deps in
  let ctx = env.ctx in
  let session_id = env.session_id in
  let wait_mode = env.wait_mode in
  let append_spawn_event = Tool_team_session_step_exec.append_spawn_event env in
  let append_spawn_requested_event =
    Tool_team_session_step_exec.append_spawn_requested_event env
  in
  let persist_worker_run_snapshot =
    Tool_team_session_step_exec.persist_worker_run_snapshot env
  in
  let release_prepared_runtime =
    Tool_team_session_step_exec.release_prepared_runtime
  in
  let fail_all_prepared =
    Tool_team_session_step_exec.fail_all_prepared env
  in
  match prepared_spawns_result with
  | Error msg -> Some (`Assoc [ ("error", `String msg) ])
  | Ok [] -> None
  | Ok prepared_spawns ->
      let planned_workers =
        List.map
          (fun prepared ->
            deps.planned_worker_of_spec
              ?runtime_actor:prepared.runtime_actor_name
              prepared.spec)
          prepared_spawns
      in
      let planning_error =
        match
          deps.register_planned_workers ctx.config session_id
            planned_workers
        with
        | Error msg -> Some msg
        | Ok () -> None
      in
      match planning_error with
      | Some msg ->
          fail_all_prepared ~include_worker_run_id:false prepared_spawns
            ~error:msg;
          Some (`Assoc [ ("error", `String msg) ])
      | None -> (
          match ctx.proc_mgr with
          | None ->
              let msg =
                "process manager unavailable for team step spawn"
              in
              fail_all_prepared prepared_spawns ~error:msg;
              Some (`Assoc [ ("error", `String msg) ])
          | Some _pm ->
              let rec ensure_all = function
                | [] -> Ok ()
                | prepared :: rest -> (
                    match prepared.runtime_actor_name with
                    | None -> ensure_all rest
                    | Some worker_actor -> (
                        match
                          deps.ensure_session_actor ctx.config
                            session_id worker_actor
                        with
                        | Ok () -> ensure_all rest
                        | Error msg -> Error msg))
              in
              (match ensure_all prepared_spawns with
               | Error msg ->
                   fail_all_prepared prepared_spawns ~error:msg;
                   Some (`Assoc [ ("error", `String msg) ])
               | Ok () ->
                   let execute_spawn index prepared =
                     (* Phase C-3a: Route spawn through OAS Agent.run via Oas_worker.
                        This replaces the old Spawn.spawn subprocess call, giving us
                        trace data, tool_names, and tool_call_count for free. *)
                     let start_time = Time_compat.now () in
                     let max_turns =
                       match prepared.spec.max_turns with
                       | Some n -> n | None -> 10
                     in
                     let oas_result =
                       Oas_worker.run_model_by_label
                         ~model_label:prepared.runtime_model_label
                         ~goal:prepared.spec.spawn_prompt
                         ~system_prompt:(Printf.sprintf
                           "You are agent '%s'. Execute the task and return a clear result."
                           prepared.spec.spawn_agent)
                         ~max_turns
                         ~temperature:(Safe_ops.get_env_float_logged
                           "MASC_SPAWN_TEMPERATURE" ~default:0.3)
                         ~max_tokens:(Safe_ops.get_env_int_logged
                           "MASC_SPAWN_MAX_TOKENS" ~default:4096)
                         ~priority:Oas.Llm_provider.Request_priority.Interactive
                         ~sw:ctx.sw
                         ()
                     in
                     let elapsed_ms =
                       int_of_float ((Time_compat.now () -. start_time) *. 1000.0)
                     in
                     let spawn_result, oas_trace_ref, oas_tool_names, oas_tool_call_count,
                         trace_summary_json, trace_validation_json =
                       match oas_result with
                       | Ok result ->
                         let text = Agent_sdk.Types.text_of_content result.response.content in
                         let tool_names =
                           List.filter_map (function
                             | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                             | _ -> None)
                             result.response.content
                         in
                         let usage = result.response.usage in
                         let cost_usd =
                           Option.map (fun (cp : Agent_sdk.Checkpoint.t) ->
                             cp.usage.estimated_cost_usd) result.checkpoint
                         in
                         let trace_summary =
                           Some (`Assoc [
                             ("oas_session_id", `String result.session_id);
                             ("turns", `Int result.turns);
                             ("model", `String prepared.runtime_model_label);
                             ("tool_names", `List (List.map (fun n -> `String n) tool_names));
                             ("tool_call_count", `Int (List.length tool_names));
                             ("input_tokens",
                               Option.fold ~none:`Null
                                 ~some:(fun (u : Agent_sdk.Types.api_usage) -> `Int u.input_tokens) usage);
                             ("output_tokens",
                               Option.fold ~none:`Null
                                 ~some:(fun (u : Agent_sdk.Types.api_usage) -> `Int u.output_tokens) usage);
                           ])
                         in
                         ({ Spawn.success = true;
                            output = text;
                            exit_code = 0;
                            elapsed_ms;
                            input_tokens = Option.map (fun (u : Agent_sdk.Types.api_usage) -> u.input_tokens) usage;
                            output_tokens = Option.map (fun (u : Agent_sdk.Types.api_usage) -> u.output_tokens) usage;
                            cache_creation_tokens = Option.map (fun (u : Agent_sdk.Types.api_usage) -> u.cache_creation_input_tokens) usage;
                            cache_read_tokens = Option.map (fun (u : Agent_sdk.Types.api_usage) -> u.cache_read_input_tokens) usage;
                            cost_usd;
                          },
                          Some { Agent_sdk.Raw_trace.worker_run_id = prepared.worker_run_id;
                                path = result.session_id; start_seq = 0; end_seq = result.turns;
                                agent_name = prepared.spec.spawn_agent;
                                session_id = Some result.session_id },
                          tool_names,
                          List.length tool_names,
                          trace_summary,
                          (None : Yojson.Safe.t option))
                       | Error e ->
                         ({ Spawn.success = false;
                            output = e;
                            exit_code = 1;
                            elapsed_ms;
                            input_tokens = None;
                            output_tokens = None;
                            cache_creation_tokens = None;
                            cache_read_tokens = None;
                            cost_usd = None;
                          },
                          None,
                          [],
                          0,
                          None,
                          None)
                     in
                     let output_preview =
                       deps.truncate_for_event spawn_result.output
                     in
                     let verification_outcome =
                       match oas_result with
                       | Ok result ->
                           let model_used =
                             if String.trim result.response.model <> "" then
                               result.response.model
                             else prepared.runtime_model_label
                           in
                           let run_result : Worker_container_types.run_result =
                             {
                               output = spawn_result.output;
                               model_used;
                               input_tokens = spawn_result.input_tokens;
                               output_tokens = spawn_result.output_tokens;
                               cost_usd = spawn_result.cost_usd;
                               tool_call_count = oas_tool_call_count;
                               tool_names = oas_tool_names;
                               session_id = result.session_id;
                               raw_trace_run = oas_trace_ref;
                               api_response = Some result.response;
                             }
                           in
                           let goal =
                             match
                               Team_session_store.load_session ctx.config
                                 session_id
                             with
                             | Some session -> session.goal
                             | None -> prepared.spec.spawn_prompt
                           in
                           Some
                             (Worker_verification.verify_worker_result
                                ?delivery_contract:
                                  (Tool_team_session_step_exec
                                   .delivery_contract_for_session
                                     ctx.config session_id)
                                ~goal run_result)
                       | Error _ -> None
                     in
                     Option.iter
                       (Tool_team_session_step_exec
                        .record_delivery_verdict_for_worker_run
                          ~config:ctx.config ~session_id
                          ~worker_run_id:prepared.worker_run_id)
                       verification_outcome;
                     let delivery_verdict_json =
                       Tool_team_session_step_exec
                       .latest_delivery_verdict_json_for_session ctx.config
                         session_id
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
                     persist_worker_run_snapshot
                       ~worker_run_id:prepared.worker_run_id
                       ~worker_name:
                         (Option.value
                            ~default:(Printf.sprintf "spawn-%d" index)
                            prepared.runtime_actor_name)
                       ~mode:"spawn" ~wait_mode
                       ~status:
                         (if spawn_result.success then `Completed else `Failed)
                       ?execution_scope:
                         (deps.effective_execution_scope_of_spec prepared.spec)
                       ?requested_worker_class:prepared.spec.worker_class
                       ?requested_worker_size:(deps.worker_size_of_spec prepared.spec)
                       ?resolved_runtime:prepared.assigned_runtime
                       ~resolved_model:prepared.runtime_model_label
                       ?routing_reason:prepared.spec.routing_reason
                       ~tool_names:oas_tool_names
                       ~tool_call_count:oas_tool_call_count
                       ~success:spawn_result.success
                       ~output_preview
                       ~evidence_session_id:
                         (Worker_runtime
                          .oas_worker_evidence_session_id
                            ~worker_run_id:
                              prepared.worker_run_id)
                       ?trace_ref:oas_trace_ref
                       ?trace_summary:trace_summary_json
                       ?trace_validation:trace_validation_json
                         ~trace_capability:"raw"
                       ();
                     append_spawn_event
                       ~worker_run_id:prepared.worker_run_id
                       ~spawn_agent:prepared.spec.spawn_agent
                       ?runtime_actor:prepared.runtime_actor_name
                       ?spawn_role:prepared.spec.spawn_role
                       ?spawn_model:prepared.spec.spawn_model
                       ?execution_scope:
                         (deps.effective_execution_scope_of_spec prepared.spec)
                       ?worker_class:prepared.spec.worker_class
                       ?worker_size:(deps.worker_size_of_spec prepared.spec)
                       ?worker_backend:(Some "oas")
                       ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                       ~trace_capability:"raw"
                       ?parent_actor:prepared.spec.parent_actor
                       ?capsule_mode:prepared.spec.capsule_mode
                       ?runtime_pool:prepared.spec.runtime_pool
                       ?lane_id:prepared.spec.lane_id
                       ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
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
                       ~tool_names:oas_tool_names
                       ~tool_call_count:oas_tool_call_count
                       ~success:spawn_result.success
                       ~exit_code:spawn_result.exit_code
                       ~elapsed_ms:spawn_result.elapsed_ms
                       ~output_preview ();
                     (match
                        ( spawn_result.success,
                          prepared.runtime_actor_name,
                          deps.auto_note_message_of_spawn_output
                            spawn_result.output )
                      with
                     | true, Some worker_actor, Some auto_note
                       when not
                              (deps.session_has_turn_for_actor
                                 ctx.config session_id worker_actor) ->
                         ignore
                           (deps.record_session_turn_json
                              ~config:ctx.config ~session_id
                              ~actor:worker_actor
                              ~turn_kind:Team_session_types.Turn_note
                              ~message:(Some auto_note)
                              ~target_agent:None
                              ~task_title:None
                              ~task_description:None
                              ~task_priority:3)
                     | _ -> ());
                     (* Record finding for successful spawns so
                        subsequent workers see prior results *)
                     (if spawn_result.success
                         && String.length spawn_result.output > 0
                      then
                        let finding_preview =
                          let len =
                            String.length spawn_result.output
                          in
                          if len <= 200 then spawn_result.output
                          else
                            String.sub spawn_result.output 0 200
                        in
                        let worker_name =
                          Option.value
                            ~default:
                              (Printf.sprintf "spawn-%d" index)
                            prepared.runtime_actor_name
                        in
                        Team_context.add_finding
                          ~base_path:
                            ctx.config.Room_utils.base_path
                          ~team_session_id:session_id
                          ~worker_name ~finding:finding_preview);
                     (match (spawn_result.success, prepared.runtime_actor_name) with
                     | false, Some worker_actor ->
                         ignore
                           (deps.reconcile_failed_spawn_actor
                              ctx.config session_id worker_actor)
                     | _ -> ());
                     `Assoc
                       [
                         ("worker_run_id", `String prepared.worker_run_id);
                         ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                         ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                         ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) (deps.effective_execution_scope_of_spec prepared.spec));
                         ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) prepared.spec.thinking_enabled);
                         ("max_turns", Option.fold ~none:`Null ~some:(fun n -> `Int n) prepared.spec.max_turns);
                         ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                         ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (deps.worker_size_of_spec prepared.spec));
                         ("worker_backend", if deps.is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                         ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                         ("status", `String "completed");
                         ("trace_capability", `String (if Option.is_some oas_trace_ref then "raw" else "summary_only"));
                         ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                         ("resolved_model", `String prepared.runtime_model_label);
                         ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                         ("tool_call_count", `Int oas_tool_call_count);
                         ("tool_names", `List (List.map (fun name -> `String name) oas_tool_names));
                         ("success", `Bool spawn_result.success);
                         ("elapsed_ms", `Int spawn_result.elapsed_ms);
                         ("output_preview", `String output_preview);
                         ("delivery_verdict", Option.value ~default:`Null delivery_verdict_json);
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
                           append_spawn_requested_event
                             ~worker_run_id:prepared.worker_run_id
                             prepared;
                           Eio.Fiber.fork ~sw:sw_bg (fun () ->
                               try ignore (execute_spawn 0 prepared)
                               with
                               | Eio.Cancel.Cancelled _ as exn -> raise exn
                               | exn ->
                                 Log.Spawn.error
                                   "background spawn failed (worker_run_id=%s, agent=%s): %s"
                                   prepared.worker_run_id
                                   prepared.spec.spawn_agent
                                   (Printexc.to_string exn)))
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
                                    ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (deps.worker_size_of_spec prepared.spec));
                                    ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                    ("resolved_model", `String prepared.runtime_model_label);
                                    ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                    ("ready", `Bool false);
                                  ])
                       in
                       Some
                         (match accepted with
                          | [single] -> single
                          | _ ->
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
                         (match spawn_results with
                          | [single] -> single
                          | _ ->
                            `Assoc
                              [
                                ("mode", `String "batch");
                                ("count", `Int (List.length spawn_results));
                                ("results", `List spawn_results);
                              ]))))
