(** Tool_team_session_step — team session step handler.
    Spawn pipeline is in Tool_team_session_step_spawn. *)

include Tool_team_session_step_spawn
open Tool_args


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
  let append_delegate_denied_event =
    Tool_team_session_step_exec.append_delegate_denied_event env
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
              let delegate_readiness =
                Team_session_engine_status.worker_delegate_readiness
                  ctx.config session worker_name
              in
              let contract : Oas.Risk_contract.t option =
                let delivery_contract =
                  Tool_team_session_step_exec.delivery_contract_for_session
                    ctx.config session_id
                in
                Option.map
                  (fun dc -> Contract_composer.compose ~delivery_contract:dc
                    ~execution_scope
                    ~tool_names:[])
                  delivery_contract
              in
              let run_delegate () =
                match
                  Worker_runtime.continue_worker ~sw:ctx.sw
                    ~base_path:ctx.config.base_path
                    ~room_config:(Some ctx.config)
                    ~worker_name ~team_session_id:session_id
                    ~worker_run_id ?contract
                    ~prompt:delegate_prompt ()
                with
                | Ok run_result ->
                    (* OAS Verified_output: cross-agent verification *)
                    let verification_outcome =
                      let goal = match session_opt with
                        | Some s -> s.Team_session_types.goal
                        | None -> "unknown"
                      in
                      Worker_verification.verify_worker_result
                        ?delivery_contract:
                          (Tool_team_session_step_exec
                           .delivery_contract_for_session
                             ctx.config session_id)
                        ~goal run_result
                    in
                    Tool_team_session_step_exec
                    .record_delivery_verdict_for_worker_run
                      ~config:ctx.config ~session_id ~worker_run_id
                      verification_outcome;
                    let delivery_verdict_json =
                      Tool_team_session_step_exec
                      .latest_delivery_verdict_json_for_session ctx.config
                        session_id
                    in
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
                        (Worker_runtime
                         .oas_worker_evidence_session_id
                           ~worker_run_id)
                      ?trace_ref:run_result.raw_trace_run
                      ?trace_summary:trace_summary_json
                      ?trace_validation:trace_validation_json
                      ?proof:run_result.proof
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
                        ( "delivery_verdict",
                          Option.value ~default:`Null
                            delivery_verdict_json );
                      ]
                | Error err ->
                    persist_worker_run_snapshot
                      ~worker_run_id ~worker_name
                      ~mode:"delegate" ~wait_mode
                      ~status:`Failed
                      ~resolved_runtime:"local"
                      ~success:false ~error:err
                      ~evidence_session_id:
                        (Worker_runtime
                         .oas_worker_evidence_session_id
                           ~worker_run_id)
                      ?proof:None
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
              match delegate_readiness with
              | Some readiness when not readiness.delegate_ready ->
                  let readiness_json =
                    Team_session_engine_status.worker_delegate_readiness_to_json
                      readiness
                  in
                  let blocked_reason =
                    Option.value ~default:"not_ready" readiness.blocked_reason
                  in
                  let err =
                    Printf.sprintf
                      "target worker '%s' is not ready for delegation (%s). %s \
                       See status.worker_runs.delegate_ready_worker_names and \
                       status.worker_runs.worker_readiness."
                      worker_name blocked_reason readiness.guidance
                  in
                  append_delegate_denied_event ~worker_name ~delegate_prompt
                    ~blocked_reason ~guidance:readiness.guidance
                    ~readiness:readiness_json;
                  Some
                    (`Assoc
                      [
                        ("error", `String err);
                        ("readiness", readiness_json);
                      ])
              | _ -> (
                  match wait_mode with
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
                          try ignore (run_delegate ())
                          with
                          | Eio.Cancel.Cancelled _ as exn -> raise exn
                          | exn ->
                            let err = Printexc.to_string exn in
                            Log.Spawn.error
                              "background delegate failed (worker_run_id=%s, agent=%s): %s"
                              worker_run_id worker_name err;
                            append_delegate_event ~worker_run_id
                              ~worker_name ~delegate_prompt
                              ?execution_scope
                              ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                              ~trace_capability:"summary_only"
                              ~resolved_runtime:"local"
                              ~success:false ~error:err ());
                      Some
                        (`Assoc
                          [
                            ("worker_run_id", `String worker_run_id);
                            ("worker_name", `String worker_name);
                            ("worker_backend", `String "local");
                            ("status", `String "accepted");
                            ("wait_mode", `String "background");
                          ])))))

let non_empty_string_list_of_json = function
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
      |> Team_session_types.dedup_strings
  | _ -> []

let parse_delivery_contract_update args ~actor
    ~(existing : Team_session_types.delivery_contract option)
    ~(session_goal : string) :
    (Team_session_types.delivery_contract option, string) Result.t =
  match Yojson.Safe.Util.member "delivery_contract" args with
  | `Null -> Ok None
  | `Assoc fields ->
      let pick_string key fallback =
        match List.assoc_opt key fields with
        | Some (`String value) ->
            let trimmed = String.trim value in
            if trimmed = "" then fallback else trimmed
        | _ -> fallback
      in
      let pick_string_list key fallback =
        match List.assoc_opt key fields with
        | Some value -> non_empty_string_list_of_json value
        | None -> fallback
      in
      let pick_int key fallback =
        match List.assoc_opt key fields with
        | Some (`Int value) -> max 0 value
        | Some (`Intlit raw) -> (
            match int_of_string_opt raw with Some v -> max 0 v | None -> fallback)
        | _ -> fallback
      in
      let pick_opt_string key fallback =
        match List.assoc_opt key fields with
        | Some (`String value) ->
            let trimmed = String.trim value in
            if trimmed = "" then None else Some trimmed
        | Some `Null -> None
        | _ -> fallback
      in
      let contract =
        {
          Team_session_types.contract_id =
            pick_string "contract_id"
              (match existing with
              | Some current -> current.contract_id
              | None -> "contract-" ^ Team_session_store.make_session_id ());
          summary =
            pick_string "summary"
              (match existing with
              | Some current when String.trim current.summary <> "" ->
                  current.summary
              | _ -> session_goal);
          acceptance_checks =
            pick_string_list "acceptance_checks"
              (match existing with
              | Some current -> current.acceptance_checks
              | None -> []);
          required_artifacts =
            pick_string_list "required_artifacts"
              (match existing with
              | Some current -> current.required_artifacts
              | None -> []);
          repair_budget =
            pick_int "repair_budget"
              (match existing with
              | Some current -> current.repair_budget
              | None -> 0);
          generator_roles =
            pick_string_list "generator_roles"
              (match existing with
              | Some current -> current.generator_roles
              | None -> []);
          evaluator_role =
            pick_opt_string "evaluator_role"
              (match existing with
              | Some current -> current.evaluator_role
              | None -> None);
          evaluator_cascade =
            pick_string "evaluator_cascade"
              (match existing with
              | Some current when String.trim current.evaluator_cascade <> "" ->
                  current.evaluator_cascade
              | _ -> "cross_verifier");
          evidence_refs =
            pick_string_list "evidence_refs"
              (match existing with
              | Some current -> current.evidence_refs
              | None -> []);
          updated_by = actor;
          updated_at_iso = Types.now_iso ();
        }
      in
      if
        String.trim contract.summary = ""
        && contract.acceptance_checks = []
        && contract.required_artifacts = []
      then
        Error
          "delivery_contract requires summary, acceptance_checks, or required_artifacts"
      else Ok (Some contract)
  | _ -> Error "delivery_contract must be an object when provided"

let apply_delivery_contract_update ~(config : Room.config) ~(session_id : string)
    (contract : Team_session_types.delivery_contract) : unit =
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           delivery_contract = Some contract;
           updated_at_iso = Types.now_iso ();
         }));
  Team_session_store.append_event config session_id
    ~event_type:"delivery_contract_updated"
    ~detail:
      (`Assoc
        [
          ("contract", Team_session_types.delivery_contract_to_yojson contract);
          ("actor", `String contract.updated_by);
          ("ts_iso", `String contract.updated_at_iso);
        ])

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
              let delivery_contract_result =
                parse_delivery_contract_update args ~actor
                  ~existing:
                    (Option.bind session_opt (fun session ->
                         session.Team_session_types.delivery_contract))
                  ~session_goal:
                    (match session_opt with
                    | Some session -> session.goal
                    | None -> "")
              in
              match delivery_contract_result with
              | Error e -> (false, deps.json_error e)
              | Ok delivery_contract_update ->
              Option.iter
                (apply_delivery_contract_update ~config:ctx.config
                   ~session_id)
                delivery_contract_update;
              let session_opt =
                Team_session_store.load_session ctx.config session_id
              in
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
              let check_json_error json_opt =
                match json_opt with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Error e
                    | _ -> Ok ())
                | _ -> Ok ()
              in
              (match
                let open Result_syntax in
                let* () = check_json_error spawn_result_json in
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
              let* turn_json = turn_json_result in
              (* Execute delegate pipeline *)
              let delegate_result_json =
                execute_delegate_pipeline env ~session_opt
                  ~delegate_prompt ~target_agent
                  ~has_spawns:(spawn_specs <> [])
              in
              let* () = check_json_error delegate_result_json in
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
              let* () = check_json_error vote_result_json in
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
                    let task_link_json =
                      let operation_id =
                        Team_session_store.operation_id_for_session
                          ctx.config session_id
                      in
                      match
                        Room.link_task_execution_artifacts_r
                          ctx.config ~task_id:run_task_id
                          ~session_id ?operation_id ()
                      with
                      | Ok message ->
                          `Assoc
                            [
                              ("status", `String "ok");
                              ("message", `String message);
                            ]
                      | Error error ->
                          `Assoc
                            [
                              ("status", `String "error");
                              ( "message",
                                `String
                                  (Types.masc_error_to_string error)
                              );
                            ]
                    in
                    Some
                      (`Assoc
                        [
                          ("task_id", `String run_task_id);
                          ("init", init_json);
                          ("note", note_json);
                          ("deliverable", deliverable_json);
                          ("task_link", task_link_json);
                        ])
              in
              let refreshed_session =
                Team_session_store.load_session ctx.config
                  session_id
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
                    ( "delivery_contract",
                      Option.fold ~none:`Null
                        ~some:Team_session_types
                          .delivery_contract_to_yojson
                        (Option.bind refreshed_session
                           (fun session ->
                             session.Team_session_types
                             .delivery_contract)) );
                    ( "latest_delivery_verdict",
                      Option.fold ~none:`Null
                        ~some:Team_session_types
                          .delivery_verdict_to_yojson
                        (Option.bind refreshed_session
                           (fun session ->
                             session.Team_session_types
                             .latest_delivery_verdict)) );
                  ]
              in
              Ok (true, deps.json_ok [ ("result", response) ])
              with
              | Ok v -> v
              | Error e -> (false, deps.json_error e)))
