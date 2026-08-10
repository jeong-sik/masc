open Result.Syntax

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_core.Error.Internal detail

module Host = Keeper_official_client_host

let runtime_label = "Codex"

let finish_raw_error ~keeper_name raw_trace_run error =
  match raw_trace_run with
  | None -> ()
  | Some active ->
    ignore
      (Host.observe_raw_trace ~keeper_name ~stage:Host.Run_finish (fun () ->
         Agent_core.Raw_trace.finish_run
           active
           ~final_text:None
           ~stop_reason:None
           ~error:(Some (Agent_core.Error.to_string error))))
;;

let finish_raw_success ~keeper_name raw_trace_run (result : Runtime_agent.run_result) =
  match raw_trace_run with
  | None -> result
  | Some active ->
    let all_blocks_recorded = ref true in
    result.response.content
    |> List.iteri (fun block_index block ->
      if
        Option.is_none
          (Host.observe_raw_trace
             ~keeper_name
             ~stage:Host.Assistant_block
             (fun () ->
                Agent_core.Raw_trace.record_assistant_block active ~block_index block))
      then all_blocks_recorded := false);
    let finished =
      Host.observe_raw_trace ~keeper_name ~stage:Host.Run_finish (fun () ->
         Agent_core.Raw_trace.finish_run
           active
           ~final_text:
             (Agent_core.Types.text_of_response result.response
              |> String_util.trim_to_option)
           ~stop_reason:
             (Some
                (Agent_core.Types.stop_reason_to_string
                   result.response.stop_reason))
           ~error:None)
    in
    (match !all_blocks_recorded, finished with
     | true, Some trace_ref -> { result with trace_ref = Some trace_ref }
     | false, _ | _, None -> result)
;;

let project_messages messages =
  let rec loop developer history = function
    | [] -> Ok (List.rev developer, List.rev history)
    | (message : Agent_core.Types.message) :: rest ->
      let* text =
        Host.text_of_blocks
          ~runtime_label
          ~field:"initial_messages"
          message.content
      in
      (match message.role with
       | Agent_core.Types.System -> loop (text :: developer) history rest
       | Agent_core.Types.User ->
         loop developer
           ({ Runtime_codex_app_server.role = User; text } :: history)
           rest
       | Agent_core.Types.Assistant ->
         loop developer
           ({ Runtime_codex_app_server.role = Assistant; text } :: history)
           rest
       | Agent_core.Types.Tool ->
         Error
           (config_error
              ~field:"initial_messages"
              "codex-app-server history injection does not admit AGENT_CORE tool messages"))
  in
  loop [] [] messages
;;

let codex_dynamic_tool (tool : Host.dynamic_tool) :
    Runtime_codex_app_server.dynamic_tool =
  { name = tool.name
  ; description = tool.description
  ; input_schema = tool.input_schema
  ; call =
      (fun ~call_id input ->
        let result = tool.call ~call_id input in
        { Runtime_codex_app_server.success = result.success
        ; content = result.content
        })
  }
;;

let codex_error_to_core_error = function
  | Runtime_codex_app_server.Invalid_config detail ->
    config_error ~field:"codex_app_server" detail
  | Runtime_codex_app_server.Subscription_required detail ->
    config_error ~field:"codex_subscription" detail
  | error -> Agent_core.Error.Internal (Runtime_codex_app_server.error_to_string error)
;;

let recovery_failure_of_client_error = function
  | Runtime_codex_app_server.Spawn_failed _ ->
    Keeper_official_client_session_store.Transient_spawn_failed
  | Runtime_codex_app_server.Turn_interrupted
  | Runtime_codex_app_server.Process_exited _
  | Runtime_codex_app_server.Timeout _ ->
    Keeper_official_client_session_store.Transport_interrupted
  | Runtime_codex_app_server.Invalid_config _
  | Runtime_codex_app_server.Protocol_error _
  | Runtime_codex_app_server.Rpc_error _
  | Runtime_codex_app_server.Unsupported_server_request _ ->
    Keeper_official_client_session_store.Protocol_failed
  | Runtime_codex_app_server.Subscription_required _
  | Runtime_codex_app_server.Turn_failed _ ->
    Keeper_official_client_session_store.Provider_rejected
;;

let run_without_lifecycle ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection ~hooks
    ~context_injector ~context ~event_bus ~raw_trace
    ~(config : Runtime_execution.codex_app_server) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Codex app-server runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Codex app-server runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks = match hooks with Some hooks -> hooks | None -> Agent_core.Hooks.empty in
    let owner_epoch = Keeper_official_client_session_store.process_epoch () in
    let* stored_session =
      match Keeper_official_client_session_store.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Codex session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some
          ({ phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        (match
           Keeper_official_client_session_store.reconcile_process_restart
             ~base_path
             ~keeper_name
             ~expected
             ~current_owner_epoch:owner_epoch
             ~required_at:(Time_compat.now ())
         with
         | Ok reconciled -> Ok (Some reconciled)
         | Error detail ->
           Error
             (config_error
                ~field:"official_client_session.phase"
                detail))
      | None | Some { phase = (Ready | Recovery_required _ | Settled _); _ } ->
        Ok stored_session
    in
    let* claim_plan =
      match
        Keeper_official_client_session_store.plan_claim
          ~expected:stored_session
          ~client_kind:Codex
          ~runtime_id
      with
      | Ok plan -> Ok plan
      | Error detail ->
        Error
          (config_error
             ~field:"official_client_session.claim"
             detail)
    in
    (* Before the plan is read. A moved surface has to change thread_mode and
       the ordinal too, not just what the store writes, or the adapter asks the
       provider to resume a thread the store has already replaced.
       [Host.prepare_turn] returns the same list it was given -- it only
       validates forced tool choice -- so hashing the input here is the digest
       that reaches [claim]. *)
    let tool_surface_sha256 =
      Keeper_official_client_session_store.tool_surface_sha256 tools
    in
    let claim_plan =
      Keeper_official_client_session_store.reconcile_tool_surface
        claim_plan
        ~tool_surface_sha256
    in
    let thread_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_codex_app_server.Start
      | Some { session_id; _ } ->
        Runtime_codex_app_server.Resume { thread_id = session_id }
    in
    let turn_count = claim_plan.turn_count in
    let* prepared =
      Host.prepare_turn
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~system_prompt
        ~tools
        ~initial_messages
        ~model_input_projection
        ~hooks:(Some hooks)
    in
    let* developer_messages, history = project_messages prepared.messages in
    let* prompt =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks ->
        Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let developer_instructions =
      prepared.system_prompt :: developer_messages
      |> List.filter (fun text -> String.trim text <> "")
      |> String.concat "\n\n"
      |> String_util.trim_to_option
    in
    let client_config =
      { Runtime_codex_app_server.cli_path = config.cli_path
      ; model = config.model
      ; developer_instructions
      ; timeout_s = config.timeout_s
      }
    in
    let terminal_error = ref None in
    let* host_dynamic_tools =
      Host.dynamic_tools
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_error
        ~raw_trace_run:None
    in
    let dynamic_tools = List.map codex_dynamic_tool host_dynamic_tools in
    let* () =
      match
        Runtime_codex_app_server.validate_turn
          ~dynamic_tools
          ~thread_mode
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
          client_config
          ~prompt
      with
      | Ok () -> Ok ()
      | Error error -> Error (codex_error_to_core_error error)
    in
    let raw_trace_run =
      match raw_trace with
      | None -> None
      | Some sink ->
        Host.observe_raw_trace ~keeper_name ~stage:Host.Run_start (fun () ->
          Agent_core.Raw_trace.start_run
            sink
            ~agent_name:keeper_name
            ~prompt
            ?model:config.model
            ?reasoning_effort:
              (Option.map
                 Llm_provider.Reasoning_effort.to_string
                 prepared.reasoning_effort)
            ())
    in
    let* host_dynamic_tools =
      Host.dynamic_tools
        ~runtime_label
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_error
        ~raw_trace_run
    in
    let dynamic_tools = List.map codex_dynamic_tool host_dynamic_tools in
    let* claimed_session =
      match
        Keeper_official_client_session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Codex
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        let error = internal_error ("Codex session claim failed: " ^ detail) in
        finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    let session_state = ref claimed_session in
    let recovery_failure =
      ref Keeper_official_client_session_store.Transport_interrupted
    in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        recovery_failure := Keeper_official_client_session_store.State_persistence_failed;
        Error (Printf.sprintf "Codex session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Keeper_official_client_session_store.phase =
            (Ready | Settled _ | Recovery_required _)
        ; _
        } ->
        Ok ()
      | expected ->
        (match
           Keeper_official_client_session_store.require_recovery
             ~base_path
             ~keeper_name
             ~expected
             ~failure:!recovery_failure
             ~detail
             ~required_at:(Time_compat.now ())
         with
         | Ok recovery ->
           session_state := recovery;
           Ok ()
         | Error detail -> Error detail)
    in
    let settle_failed_claim detail =
      match
        Keeper_official_client_session_store.failure_disposition
          !recovery_failure
      with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           (match
              Keeper_official_client_session_store.release_transient
                ~base_path
                ~keeper_name
                ~expected
                ~failure:!recovery_failure
                ~released_at:(Time_compat.now ())
            with
            | Ok released ->
              session_state := released;
              Ok ()
            | Error detail -> Error detail))
      | Ambiguous | Fatal -> require_recovery detail
    in
    let started_at = Time_compat.now () in
    let turn_result =
      try
        (match
       Runtime_codex_app_server.run_turn
         ~mgr:(Eio.Stdenv.process_mgr env)
         ~clock
         ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
         ~dynamic_tools
         ?reasoning_effort:prepared.reasoning_effort
         ~thread_mode
         ~history
         ~on_thread_ready:(fun ~thread_id ->
           update_session "active transition" (fun expected ->
             Keeper_official_client_session_store.mark_active
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_starting:(fun ~thread_id ->
           update_session "turn-starting transition" (fun expected ->
             Keeper_official_client_session_store.mark_turn_starting
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_started:(fun ~thread_id ~turn_id ->
           update_session "turn-started transition" (fun expected ->
             Keeper_official_client_session_store.mark_turn_started
               ~base_path
               ~keeper_name
               ~expected
               ~session_id:thread_id
               ~turn_id
               ~updated_at:(Time_compat.now ())))
         client_config
         ~prompt
     with
     | Error error ->
       recovery_failure := recovery_failure_of_client_error error;
       Error (codex_error_to_core_error error)
     | Ok turn ->
       recovery_failure := Keeper_official_client_session_store.Protocol_failed;
       let expected_resumed =
         match thread_mode with
         | Runtime_codex_app_server.Start -> false
         | Runtime_codex_app_server.Resume _ -> true
       in
       let* () =
         if Bool.equal expected_resumed turn.resumed
         then Ok ()
         else
           Error
             (internal_error
                "Codex app-server reported a thread mode different from the requested session plan")
       in
       recovery_failure := Keeper_official_client_session_store.Host_hook_failed;
       let* () =
         match !terminal_error with
         | None -> Ok ()
         | Some detail -> Error (internal_error detail)
       in
       let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
       let response =
         { Agent_core.Types.id = turn.turn_id
         ; model = turn.model
         ; stop_reason = EndTurn
         ; content = [ Text turn.text ]
         ; usage = None
         ; telemetry =
             Some
               { Agent_core.Types.default_inference_telemetry with
                 request_latency_ms = Some latency_ms
               ; canonical_model_id = Some turn.model
               }
         }
       in
       let after_turn =
         Host.invoke_turn_hook
           ~keeper_name
           ~turn_count
           ~hook_name:"after_turn"
           hooks.after_turn
           (Agent_core.Hooks.AfterTurn { turn = turn_count; response })
       in
       let* () =
         match after_turn with
         | Continue -> Ok ()
         | HookFailed { stage; detail } ->
           Error (Host.hook_error ~runtime_label ~hook_name:"after_turn" ~stage detail)
         | decision -> Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"after_turn" decision)
       in
       let on_stop =
         Host.invoke_turn_hook
           ~keeper_name
           ~turn_count
           ~hook_name:"on_stop"
           hooks.on_stop
           (Agent_core.Hooks.OnStop { reason = response.stop_reason; response })
       in
       let* () =
         match on_stop with
         | Continue -> Ok ()
         | HookFailed { stage; detail } ->
           Error (Host.hook_error ~runtime_label ~hook_name:"on_stop" ~stage detail)
         | decision -> Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"on_stop" decision)
       in
       recovery_failure := Keeper_official_client_session_store.State_persistence_failed;
       let* () =
         match
           Keeper_official_client_session_store.settle
             ~base_path
             ~keeper_name
             ~expected:!session_state
             ~session_id:turn.thread_id
             ~turn_id:turn.turn_id
             ~updated_at:(Time_compat.now ())
         with
         | Ok settled ->
           session_state := settled;
           Ok ()
         | Error detail ->
           Error (internal_error ("Codex session settlement failed: " ^ detail))
       in
       let capture, _metrics =
         Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
       in
       Runtime_observation.record_attempt_terminal
         capture
         ~model_id:turn.model
         ~latency_ms:(Some latency_ms)
         ~error:None;
       let runtime_observation =
         Runtime_observation.runtime_observation_with_metrics
           ~runtime_id
           ~strategy:"official_client_runtime"
           ~configured_labels:
             [ "codex_app_server"
             ; Printf.sprintf "dynamic_tool_calls=%d" turn.dynamic_tool_calls
             ; Printf.sprintf "resumed=%b" turn.resumed
             ; Printf.sprintf "turn_count=%d" turn_count
             ]
           ~candidate_count:1
           ~selected_model_raw:(Some turn.model)
           ~capture
           ~attempt_details_source:"codex_app_server"
           ~agent_core_internal_runtime_allowed:false
           ()
       in
       Ok
         { Runtime_agent.response
         ; checkpoint = None
         ; session_id = turn.thread_id
         ; turns = turn_count
         ; trace_ref = None
         ; run_validation = None
         ; runtime_observation = Some runtime_observation
         ; stop_reason = Completed
         })
      with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        recovery_failure := Keeper_official_client_session_store.Transport_interrupted;
        let detail = "Codex turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Codex cancellation recovery persistence failed: %s"
             recovery_detail);
        (match
           Eio.Cancel.protect (fun () ->
             finish_raw_error ~keeper_name raw_trace_run (internal_error detail))
         with
         | () -> ());
        Printexc.raise_with_backtrace exn backtrace
    in
    let turn_result =
      match turn_result with
      | Ok result -> Ok (finish_raw_success ~keeper_name raw_trace_run result)
      | Error error ->
        finish_raw_error ~keeper_name raw_trace_run error;
        Error error
    in
    (match turn_result with
     | Ok _ -> turn_result
     | Error original_error ->
       let original_detail = Agent_core.Error.to_string original_error in
       (match Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) with
        | Ok () -> turn_result
      | Error recovery_detail ->
        Error
            (internal_error
               (Printf.sprintf
                  "Codex turn failed and recovery state persistence also failed: original=%s recovery=%s"
               original_detail
               recovery_detail))))
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection ~hooks
    ~context_injector ~context ~event_bus ~raw_trace ~config =
  Host.with_run_lifecycle_events ~event_bus ~keeper_name (fun () ->
    run_without_lifecycle
      ~runtime_id
      ~keeper_name
      ~base_path
      ~goal
      ~goal_blocks
      ~system_prompt
      ~tools
      ~initial_messages
      ~model_input_projection
      ~hooks
      ~context_injector
      ~context
      ~event_bus
      ~raw_trace
      ~config)
;;
