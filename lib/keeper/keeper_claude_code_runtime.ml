open Result.Syntax

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_core.Error.Internal detail

module Host = Keeper_official_client_host
module Session_store = Keeper_official_client_session_store

let runtime_label = "Claude Code"

let project_messages messages =
  let rec loop system history = function
    | [] -> Ok (List.rev system, List.rev history)
    | (message : Agent_core.Types.message) :: rest ->
      (match message.role with
       | Agent_core.Types.System ->
         let* text =
           Host.text_of_blocks
             ~runtime_label
             ~field:"initial_messages"
             message.content
         in
         loop (text :: system) history rest
       | Agent_core.Types.User | Agent_core.Types.Assistant | Agent_core.Types.Tool ->
         loop
           system
           (Keeper_context_core.message_to_json message :: history)
           rest)
  in
  loop [] [] messages
;;

let initial_turn_prompt ~history ~goal =
  match history with
  | [] -> goal
  | _ :: _ ->
    `Assoc
      [ "schema", `String "masc.claude-code.initial-turn.v1"
      ; ( "history"
        , `List history )
      ; "current_goal", `String goal
      ]
    |> Yojson.Safe.to_string
;;

let claude_dynamic_tool (tool : Host.dynamic_tool) : Runtime_claude_code.dynamic_tool =
  { name = tool.name
  ; description = tool.description
  ; input_schema = tool.input_schema
  ; call =
      (fun ~call_id input ->
        let result = tool.call ~call_id input in
        { Runtime_claude_code.success = result.success; content = result.content })
  }
;;

let retry_after_of_rate_limit = function
  | None -> None
  | Some ({ resets_at = None; _ } : Runtime_claude_code.rate_limit) -> None
  | Some { resets_at = Some timestamp; _ } ->
    Some (Float.max 0.0 (Float.of_int timestamp -. Time_compat.now ()))
;;

let claude_error_to_sdk_error = function
  | Runtime_claude_code.Invalid_config detail ->
    config_error ~field:"claude_code" detail
  | Runtime_claude_code.Subscription_required detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthError { provider = "claude_code"; detail })
  | Runtime_claude_code.Quota_blocked ({ rate_limit; _ } as blocked) ->
    Agent_core.Error.Provider
      (Llm_provider.Error.HardQuota
         { provider = "claude_code"
         ; retry_after = retry_after_of_rate_limit rate_limit
         ; detail = Runtime_claude_code.error_to_string (Quota_blocked blocked)
         })
  | Runtime_claude_code.Turn_failed detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderReportedError
         { provider = "claude_code"; error_type = Some "turn_failed"; detail })
  | Runtime_claude_code.Timeout seconds ->
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout
         { message = Printf.sprintf "Claude Code turn timed out after %.3fs" seconds
         ; phase = None
         })
  | Runtime_claude_code.Spawn_failed detail
  | Runtime_claude_code.Process_exited detail ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "claude_code"; detail })
  | Runtime_claude_code.Turn_transport_interrupted _ as error ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable
         { provider = "claude_code"
         ; detail = Runtime_claude_code.error_to_string error
         })
  | Runtime_claude_code.Protocol_error { stage; detail } ->
    Agent_core.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = Printf.sprintf "%s: %s" stage detail })
  | Runtime_claude_code.Unsupported_control_request subtype ->
    Agent_core.Error.Provider
      (Llm_provider.Error.UnknownVariant
         { type_name = "claude_code.control_request"; value = subtype })
;;

let recovery_failure_of_client_error = function
  | Runtime_claude_code.Spawn_failed _ -> Session_store.Transient_spawn_failed
  | Runtime_claude_code.Process_exited _ | Runtime_claude_code.Timeout _ ->
    Session_store.Transport_interrupted
  | Runtime_claude_code.Turn_transport_interrupted _ ->
    Session_store.Transport_interrupted
  | Runtime_claude_code.Invalid_config _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Unsupported_control_request _ ->
    Session_store.Protocol_failed
  | Runtime_claude_code.Subscription_required _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Quota_blocked _ ->
    Session_store.Provider_rejected
;;

let run_without_lifecycle ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context ~event_bus
    ~(config : Runtime_execution.claude_code) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Claude Code runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Claude Code runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let hooks =
      match hooks with
      | Some hooks -> hooks
      | None -> Agent_core.Hooks.empty
    in
    let owner_epoch = Session_store.process_epoch () in
    let* stored_session =
      match Session_store.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Claude Code session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some ({ phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        (match
           Session_store.reconcile_process_restart
             ~base_path
             ~keeper_name
             ~expected
             ~current_owner_epoch:owner_epoch
             ~required_at:(Time_compat.now ())
         with
         | Ok reconciled -> Ok (Some reconciled)
         | Error detail ->
           Error (config_error ~field:"official_client_session.phase" detail))
      | None | Some { phase = (Ready | Recovery_required _ | Settled _); _ } ->
        Ok stored_session
    in
    let* claim_plan =
      match
        Session_store.plan_claim
          ~expected:stored_session
          ~client_kind:Claude_code
          ~runtime_id
      with
      | Ok plan -> Ok plan
      | Error detail ->
        Error (config_error ~field:"official_client_session.claim" detail)
    in
    let session_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_claude_code.Start
      | Some { session_id; _ } -> Runtime_claude_code.Resume { session_id }
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
    let tool_surface_sha256 = Session_store.tool_surface_sha256 prepared.tools in
    let* () =
      match claim_plan.required_tool_surface_sha256 with
      | None -> Ok ()
      | Some stored when String.equal stored tool_surface_sha256 -> Ok ()
      | Some stored ->
        Error
          (config_error
             ~field:"official_client_session.tool_surface_sha256"
             (Printf.sprintf
                "stored official-client tool surface %s does not match current surface %s"
                stored
                tool_surface_sha256))
    in
    let* system_messages, history = project_messages prepared.messages in
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
    in
    let prompt =
      match session_mode with
      | Runtime_claude_code.Start -> initial_turn_prompt ~history ~goal
      | Runtime_claude_code.Resume _ -> goal
    in
    let system_prompt =
      prepared.system_prompt :: system_messages
      |> List.filter (fun text -> String.trim text <> "")
      |> String.concat "\n\n"
      |> String_util.trim_to_option
    in
    let client_config : Runtime_claude_code.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; system_prompt
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
    let dynamic_tools = List.map claude_dynamic_tool host_dynamic_tools in
    let* () =
      match
        Runtime_claude_code.validate_turn
          ~dynamic_tools
          ~session_mode
          client_config
          ~prompt
      with
      | Ok () -> Ok ()
      | Error error -> Error (claude_error_to_sdk_error error)
    in
    let process_mgr = Eio.Stdenv.process_mgr env in
    let process_cwd = Eio.Path.(Eio.Stdenv.fs env / base_path) in
    let* admitted_subscription =
      match
        Runtime_claude_code.probe_subscription
          ~mgr:process_mgr
          ~clock
          ~cwd:process_cwd
          client_config
      with
      | Ok subscription -> Ok subscription
      | Error error -> Error (claude_error_to_sdk_error error)
    in
    let* claimed_session =
      match
        Session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Claude_code
          ~owner_epoch
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Claude Code session claim failed: " ^ detail))
    in
    let session_state = ref claimed_session in
    let recovery_failure = ref Session_store.Transport_interrupted in
    let state_persistence_failed = ref false in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        state_persistence_failed := true;
        recovery_failure := Session_store.State_persistence_failed;
        Error (Printf.sprintf "Claude Code session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Session_store.phase = (Ready | Settled _ | Recovery_required _); _ } ->
        Ok ()
      | expected ->
        (match
           Session_store.require_recovery
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
      match Session_store.failure_disposition !recovery_failure with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           (match
              Session_store.release_transient
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
           Runtime_claude_code.run_turn
             ~mgr:process_mgr
             ~clock
             ~cwd:process_cwd
             ~dynamic_tools
             ?reasoning_effort:prepared.reasoning_effort
             ~session_mode
             ~admitted_subscription
             ~on_session_ready:(fun ~session_id ->
               update_session "active transition" (fun expected ->
                 Session_store.mark_active
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~updated_at:(Time_compat.now ())))
             ~on_turn_starting:(fun ~session_id ->
               update_session "turn-starting transition" (fun expected ->
                 Session_store.mark_turn_starting
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~updated_at:(Time_compat.now ())))
             ~on_turn_started:(fun ~session_id ~turn_id ->
               update_session "turn-started transition" (fun expected ->
                 Session_store.mark_turn_started
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id
                   ~turn_id
                   ~updated_at:(Time_compat.now ())))
             client_config
             ~prompt
         with
         | Error error ->
           if not !state_persistence_failed
           then recovery_failure := recovery_failure_of_client_error error;
           Error (claude_error_to_sdk_error error)
         | Ok turn ->
           recovery_failure := Session_store.Protocol_failed;
           let expected_resumed =
             match session_mode with
             | Runtime_claude_code.Start -> false
             | Runtime_claude_code.Resume _ -> true
           in
           let* () =
             if Bool.equal expected_resumed turn.resumed
             then Ok ()
             else
               Error
                 (internal_error
                    "Claude Code reported a session mode different from the durable claim plan")
           in
           recovery_failure := Session_store.Host_hook_failed;
           let* () =
             match !terminal_error with
             | None -> Ok ()
             | Some detail -> Error (internal_error detail)
           in
           let latency_ms =
             Int.of_float ((Time_compat.now () -. started_at) *. 1000.0)
           in
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
               Error
                 (Host.hook_error
                    ~runtime_label
                    ~hook_name:"after_turn"
                    ~stage
                    detail)
             | decision ->
               Error
                 (Host.illegal_hook_decision
                    ~runtime_label
                    ~hook_name:"after_turn"
                    decision)
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
               Error
                 (Host.hook_error
                    ~runtime_label
                    ~hook_name:"on_stop"
                    ~stage
                    detail)
             | decision ->
               Error
                 (Host.illegal_hook_decision
                    ~runtime_label
                    ~hook_name:"on_stop"
                    decision)
           in
           recovery_failure := Session_store.State_persistence_failed;
           let* () =
             match
               Session_store.settle
                 ~base_path
                 ~keeper_name
                 ~expected:!session_state
                 ~session_id:turn.session_id
                 ~turn_id:turn.turn_id
                 ~updated_at:(Time_compat.now ())
             with
             | Ok settled ->
               session_state := settled;
               Ok ()
             | Error detail ->
               Error
                 (internal_error
                    ("Claude Code session settlement failed: " ^ detail))
           in
           let capture, _metrics =
             Runtime_observation.runtime_metrics_for_candidates ~candidate_count:1 ()
           in
           Runtime_observation.record_attempt_terminal
             capture
             ~model_id:turn.model
             ~latency_ms:(Some latency_ms)
             ~error:None;
           let configured_labels =
             [ "claude_code"
             ; Printf.sprintf "dynamic_tool_calls=%d" turn.dynamic_tool_calls
             ; Printf.sprintf "resumed=%b" turn.resumed
             ; Printf.sprintf "turn_count=%d" turn_count
             ; "auth_method=" ^ turn.subscription.auth_method
             ; "subscription_type=" ^ turn.subscription.subscription_type
             ]
             @
             match turn.rate_limit with
             | None -> []
             | Some rate_limit ->
               [ "rate_limit_status="
                 ^ Runtime_claude_code.rate_limit_status_to_string rate_limit.status
               ]
           in
           let runtime_observation =
             Runtime_observation.runtime_observation_with_metrics
               ~runtime_id
               ~strategy:"official_client_runtime"
               ~configured_labels
               ~candidate_count:1
               ~selected_model_raw:(Some turn.model)
               ~capture
               ~attempt_details_source:"claude_code"
               ~agent_core_internal_runtime_allowed:false
               ()
           in
           Ok
             { Runtime_agent.response
             ; checkpoint = None
             ; session_id = turn.session_id
             ; turns = turn_count
             ; trace_ref = None
             ; run_validation = None
             ; runtime_observation = Some runtime_observation
             ; stop_reason = Completed
             })
      with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        recovery_failure := Session_store.Transport_interrupted;
        let detail = "Claude Code turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Claude Code cancellation recovery persistence failed: %s"
             recovery_detail);
        Printexc.raise_with_backtrace exn backtrace
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
                  "Claude Code turn failed and recovery state persistence also failed: original=%s recovery=%s"
                  original_detail
                  recovery_detail))))
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~context ~event_bus ~config =
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
      ~config)
;;
