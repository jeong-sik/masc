(** Handler functions and dispatch for team session MCP tools.

    Each handle_* function implements one MCP tool endpoint.
    The dispatch function routes tool names to handlers. *)

open Tool_args
open Tool_team_session_support
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
      let env = object
        method clock = ctx.clock
        method process_mgr = match ctx.proc_mgr with Some pm -> pm | None -> failwith "process_mgr not available"
        method net = match ctx.net with Some n -> n | None -> failwith "net not available"
      end in
      Team_session_engine_eio.start_session ~sw:ctx.sw ~env
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

(* Routing, spawn spec parsing, model inference, worker management *)
include Tool_team_session_routing_workers

let step_deps : Tool_team_session_step.step_deps =
  {
    json_error;
    json_ok;
    get_valid_session_id;
    ensure_session_access;
    parse_step_spawn_specs;
    annotate_control_hierarchy_for_session;
    parse_turn_kind;
    parse_turn_kind_opt;
    parse_wait_mode;
    int_opt_to_json;
    float_opt_to_json;
    truncate_for_event;
    make_worker_run_id;
    derived_local_runtime_actor;
    is_local_spawn_agent;
    effective_execution_scope_of_spec;
    worker_size_of_spec;
    inferred_controller_level_of_spec;
    planned_worker_of_spec;
    register_planned_workers;
    ensure_session_actor;
    record_session_turn_json;
    resolve_target_worker_name;
    session_has_turn_for_actor;
    auto_note_message_of_spawn_output;
    reconcile_failed_spawn_actor;
    extract_vote_id;
    oas_worker_evidence_payload;
    oas_trace_capability_to_string;
    oas_worker_status_to_json = Oas.Sessions.worker_status_to_yojson;
    worker_run_status_to_json;
    raw_trace_run_ref_to_json = Oas.Raw_trace.run_ref_to_yojson;
    raw_trace_session_payloads;
  }

let handle_step ctx args : result =
  Tool_team_session_step.handle_step step_deps ctx args

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

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_step" -> Some (handle_step ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_finalize" -> Some (handle_finalize ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | "masc_team_session_events" -> Some (handle_events ctx args)
  | "masc_team_session_prove" -> Some (handle_prove ctx args)
  | "masc_team_session_verify_trace" -> Some (handle_verify_trace ctx args)
  | _ -> None
