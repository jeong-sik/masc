[@@@warning "-33"]
(** Tool_team_session_step — team session step handler. *)

include Tool_team_session_step_types
open Tool_args

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
                     let spawn_result =
                       Spawn_eio.spawn ~sw:ctx.sw
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
                         ?worker_size:(deps.worker_size_of_spec prepared.spec)
                         ?execution_scope:
                           (deps.effective_execution_scope_of_spec prepared.spec)
                         ?thinking_enabled:prepared.spec.thinking_enabled
                         ?max_turns:prepared.spec.max_turns
                         ~runtime_session_id:session_id ()
                     in
                   let output_preview =
                       deps.truncate_for_event spawn_result.output
                     in
                     let trace_summary_json, trace_validation_json =
                       match spawn_result.raw_trace_run with
                       | Some run_ref -> (
                           match
                             deps.raw_trace_session_payloads
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
                          else if deps.is_local_spawn_agent prepared.spec.spawn_agent
                          then "summary_only"
                          else "summary_only")
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
                       ?worker_backend:
                         (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                          then Some "local" else None)
                       ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                       ~trace_capability:
                         (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                          then "summary_only"
                          else "summary_only")
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
                       ~tool_names:spawn_result.tool_names
                       ~tool_call_count:spawn_result.tool_call_count
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
                              ]))))

(** Execute the delegate pipeline: validate target → continue worker → emit events.
    Returns [Some json] with result/error, or [None] if no delegate requested. *)
let execute_delegate_pipeline
    (env : _ Tool_team_session_step_exec.step_env)
    ~(session_opt : Team_session_types.session option)
    ~(delegate_prompt : string option)
    ~(target_agent : string option)
    ~(has_spawns : bool)
    : Yojson.Safe.t option =
  let deps = env.deps in
  let ctx = env.ctx in
  let session_id = env.session_id in
  let wait_mode = env.wait_mode in
  let append_delegate_event =
    Tool_team_session_step_exec.append_delegate_event env
  in
  let append_delegate_requested_event =
    Tool_team_session_step_exec.append_delegate_requested_event env
  in
  let persist_worker_run_snapshot =
    Tool_team_session_step_exec.persist_worker_run_snapshot env
  in
  match (delegate_prompt, target_agent) with
  | None, _ -> None
  | Some _, _ when has_spawns ->
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
            deps.resolve_target_worker_name ctx.config session
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
              let worker_run_id = deps.make_worker_run_id () in
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
                      deps.truncate_for_event run_result.output
                    in
                    let trace_summary_json, trace_validation_json =
                      match run_result.raw_trace_run with
                      | Some run_ref -> (
                          match
                            deps.raw_trace_session_payloads
                              ~config:ctx.config
                              ~fallback_session_id:session_id
                              run_ref
                          with
                          | Some pair -> (Some (fst pair), Some (snd pair))
                          | None -> (None, None))
                      | None -> (None, None)
                    in
                    persist_worker_run_snapshot
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
                    append_delegate_event ~worker_run_id
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
                          deps.int_opt_to_json run_result.input_tokens );
                        ( "output_tokens",
                          deps.int_opt_to_json run_result.output_tokens );
                        ( "cost_usd",
                          deps.float_opt_to_json run_result.cost_usd );
                      ]
                | Error err ->
                    persist_worker_run_snapshot
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
                    append_delegate_event ~worker_run_id
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
                  append_delegate_requested_event
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

let handle_step (deps : step_deps) (ctx : _ context) args : result =
  match deps.get_valid_session_id args with
  | Error e -> (false, deps.json_error e)
  | Ok session_id -> (
      match deps.ensure_session_access ctx session_id with
      | Error e -> (false, deps.json_error e)
      | Ok () ->
          let session_opt = Team_session_store.load_session ctx.config session_id in
          let spawn_specs_result = deps.parse_step_spawn_specs args in
          match spawn_specs_result with
          | Error e -> (false, deps.json_error e)
          | Ok raw_spawn_specs ->
              let spawn_specs =
                match session_opt with
                | Some session ->
                    deps.annotate_control_hierarchy_for_session session raw_spawn_specs
                | None -> raw_spawn_specs
              in
              let delegate_prompt_opt = get_string_opt args "delegate_prompt" in
              let turn_kind_result =
                if spawn_specs <> [] || Option.is_some delegate_prompt_opt then
                  deps.parse_turn_kind_opt args
                else
                  match deps.parse_turn_kind args with
                  | Ok kind -> Ok (Some kind)
                  | Error e -> Error e
              in
              match turn_kind_result with
              | Error e -> (false, deps.json_error e)
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
              | Error e -> (false, deps.json_error e)
              | Ok actor ->
              let wait_mode = deps.parse_wait_mode args in
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let delegate_prompt = delegate_prompt_opt in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              let env : _ Tool_team_session_step_exec.step_env =
                { deps; ctx; session_id; actor; wait_mode }
              in
              (* Prepare spawns *)
              let append_spawn_event = Tool_team_session_step_exec.append_spawn_event env in
              let release_all_prepared = Tool_team_session_step_exec.release_all_prepared in
              let prepared_spawns_result =
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | spec :: rest -> (
                      match Tool_team_session_step_exec.prepare_spawn env spec with
                      | Ok prepared -> loop (prepared :: acc) rest
                      | Error (failed_spec, runtime_actor_name, msg) ->
                          release_all_prepared (List.rev acc) ~error:msg;
                          append_spawn_event ~spawn_agent:failed_spec.spawn_agent
                            ?runtime_actor:runtime_actor_name
                            ?spawn_role:failed_spec.spawn_role
                            ?spawn_model:failed_spec.spawn_model
                            ?execution_scope:
                              (deps.effective_execution_scope_of_spec failed_spec)
                            ?worker_class:failed_spec.worker_class
                            ?worker_size:(deps.worker_size_of_spec failed_spec)
                            ?worker_backend:
                              (if deps.is_local_spawn_agent failed_spec.spawn_agent
                               then Some "local" else None)
                            ?parent_actor:failed_spec.parent_actor
                            ?capsule_mode:failed_spec.capsule_mode
                            ?runtime_pool:failed_spec.runtime_pool
                            ?lane_id:failed_spec.lane_id
                            ?controller_level:(deps.inferred_controller_level_of_spec failed_spec)
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
              (* Execute spawn pipeline *)
              let spawn_result_json =
                execute_spawn_pipeline env prepared_spawns_result
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
              | Some e -> (false, deps.json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        deps.record_session_turn_json ~config:ctx.config ~session_id
                          ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, deps.json_error e)
                  | Ok turn_json ->
                      (* Execute delegate pipeline *)
                      let delegate_result_json =
                        execute_delegate_pipeline env ~session_opt
                          ~delegate_prompt ~target_agent
                          ~has_spawns:(spawn_specs <> [])
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
                      | Some e -> (false, deps.json_error e)
                      | None ->
                      (* Vote pipeline *)
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
                              let vote_id = deps.extract_vote_id vote_create_msg in
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
                      | Some e -> (false, deps.json_error e)
                      | None ->
                          (* Run task pipeline *)
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
                                                  ("deliverable_preview", `String (deps.truncate_for_event content));
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
                          (true, deps.json_ok [ ("result", response) ]))
