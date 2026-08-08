open Result.Syntax

let config_error ~field detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_sdk.Error.Internal detail

let text_of_blocks ~field blocks =
  let rec loop texts = function
    | [] -> Ok (String.concat "\n" (List.rev texts))
    | Agent_sdk.Types.Text text :: rest -> loop (text :: texts) rest
    | _ :: _ ->
      Error
        (config_error
           ~field
           "codex-app-server Keeper projection currently admits text blocks only")
  in
  loop [] blocks
;;

let project_messages messages =
  let rec loop developer history = function
    | [] -> Ok (List.rev developer, List.rev history)
    | (message : Agent_sdk.Types.message) :: rest ->
      let* text = text_of_blocks ~field:"initial_messages" message.content in
      (match message.role with
       | Agent_sdk.Types.System -> loop (text :: developer) history rest
       | Agent_sdk.Types.User ->
         loop developer
           ({ Runtime_codex_app_server.role = User; text } :: history)
           rest
       | Agent_sdk.Types.Assistant ->
         loop developer
           ({ Runtime_codex_app_server.role = Assistant; text } :: history)
           rest
       | Agent_sdk.Types.Tool ->
         Error
           (config_error
              ~field:"initial_messages"
              "codex-app-server history injection does not admit OAS tool messages"))
  in
  loop [] [] messages
;;

let user_message text : Agent_sdk.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let system_message text : Agent_sdk.Types.message =
  { role = System
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let last_tool_results messages =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_sdk.Types.message) ->
    match message.role with
    | Tool ->
      Some
        (List.filter_map
           (function
             | Agent_sdk.Types.ToolResult { content; outcome; _ } ->
               Some (Agent_sdk.Types.tool_result_of_outcome ~content outcome)
             | _ -> None)
           message.content)
    | System | User | Assistant -> None)
  |> Option.value ~default:[]
;;

let hook_error ~hook_name ~stage detail =
  internal_error
    (Printf.sprintf
       "Codex runtime %s hook failed at %s: %s"
       hook_name
       (Agent_sdk.Hooks.hook_stage_to_string stage)
       detail)
;;

let illegal_hook_decision ~hook_name decision =
  config_error
    ~field:"hooks"
    (Printf.sprintf
       "Codex runtime %s hook returned unsupported decision %s"
       hook_name
       (Agent_sdk.Hooks.decision_kind_to_string
          (Agent_sdk.Hooks.classify_decision decision)))
;;

let invoke_turn_hook ~keeper_name ~turn_count ~hook_name hook event =
  Agent_sdk.Agent_tools.invoke_hook
    ~tracer:Agent_sdk.Tracing.null
    ~agent_name:keeper_name
    ~turn_count
    ~hook_name
    hook
    event
;;

type prepared_turn =
  { messages : Agent_sdk.Types.message list
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

let prepare_turn ~keeper_name ~turn_count ~system_prompt ~tools ~initial_messages
    ~model_input_projection ~hooks ~enable_thinking =
  let hooks = Option.value hooks ~default:Agent_sdk.Hooks.empty in
  let before_turn =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn"
      hooks.before_turn
      (Agent_sdk.Hooks.BeforeTurn { turn = turn_count; messages = initial_messages })
  in
  let* messages =
    match before_turn with
    | Continue -> Ok initial_messages
    | Nudge text -> Ok (initial_messages @ [ user_message text ])
    | HookFailed { stage; detail } -> Error (hook_error ~hook_name:"before_turn" ~stage detail)
    | decision -> Error (illegal_hook_decision ~hook_name:"before_turn" decision)
  in
  let current_params =
    { Agent_sdk.Hooks.default_turn_params with enable_thinking }
  in
  let before_turn_params =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn_params"
      hooks.before_turn_params
      (Agent_sdk.Hooks.BeforeTurnParams
         { turn = turn_count
         ; messages
         ; last_tool_results = last_tool_results messages
         ; current_params
         ; reasoning = Agent_sdk.Hooks.empty_reasoning_summary
         })
  in
  let* turn_params =
    match before_turn_params with
    | Continue -> Ok current_params
    | AdjustParams params -> Ok params
    | HookFailed { stage; detail } ->
      Error (hook_error ~hook_name:"before_turn_params" ~stage detail)
    | decision -> Error (illegal_hook_decision ~hook_name:"before_turn_params" decision)
  in
  let messages =
    match turn_params.extra_system_context with
    | None -> messages
    | Some text -> messages @ [ system_message text ]
  in
  let* messages =
    match model_input_projection with
    | None -> Ok messages
    | Some project ->
      (try
         match project messages with
         | Ok projected -> Ok projected
         | Error detail -> Error (config_error ~field:"model_input_projection" detail)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Error
           (internal_error
              ("Codex runtime model input projection raised: "
               ^ Printexc.to_string exn)))
  in
  let system_prompt =
    Option.value turn_params.system_prompt_override ~default:system_prompt
  in
  let unsupported_parameter field value =
    match value with
    | None -> Ok ()
    | Some _ ->
      Error
        (config_error
           ~field
           "codex-app-server does not yet project this turn parameter; refusing to ignore it")
  in
  let* () = unsupported_parameter "temperature" turn_params.temperature in
  let* () = unsupported_parameter "thinking_budget" turn_params.thinking_budget in
  let* () = unsupported_parameter "preserve_thinking" turn_params.preserve_thinking in
  let* reasoning_effort =
    match turn_params.enable_thinking, turn_params.reasoning_effort with
    | Some false, Some Llm_provider.Reasoning_effort.None_
    | Some false, None -> Ok (Some Llm_provider.Reasoning_effort.None_)
    | Some false, Some _ ->
      Error
        (config_error
           ~field:"reasoning_effort"
           "enable_thinking=false conflicts with a non-none reasoning effort")
    | Some true, Some Llm_provider.Reasoning_effort.None_ ->
      Error
        (config_error
           ~field:"reasoning_effort"
           "enable_thinking=true conflicts with reasoning effort none")
    | (Some true | None), reasoning_effort -> Ok reasoning_effort
  in
  let* tools =
    match turn_params.tool_choice with
    | None | Some Auto -> Ok tools
    | Some None_ -> Ok []
    | Some (Any | Tool _) as choice ->
      Error
        (config_error
           ~field:"tool_choice"
           (Printf.sprintf
              "Codex dynamic tools do not support forced tool choice %s"
              (Yojson.Safe.to_string
                 (Agent_sdk.Types.tool_choice_to_json (Option.get choice)))))
  in
  Ok { messages; system_prompt; tools; reasoning_effort }
;;

let tool_hook_error_to_string = function
  | Agent_sdk.Agent_tools.Hook_execution_failed
      { hook_name; stage; tool_name; detail; _ } ->
    Printf.sprintf
      "%s hook failed at %s for tool %s: %s"
      hook_name
      (Agent_sdk.Hooks.hook_stage_to_string stage)
      tool_name
      detail
;;

let record_terminal_error terminal_error detail =
  if Option.is_none !terminal_error then terminal_error := Some detail
;;

let apply_context_injection ~terminal_error ~context ~context_injector ~tool_name
    ~input ~content ~outcome =
  match context_injector with
  | None -> ()
  | Some inject ->
    let output = Agent_sdk.Types.tool_result_of_outcome ~content outcome in
    (try
       match inject ~tool_name ~input ~output with
       | None -> ()
       | Some (injection : Agent_sdk.Hooks.injection) ->
         List.iter (fun (key, value) -> Agent_sdk.Context.set context key value)
           injection.context_updates;
         if injection.extra_messages <> []
         then
           record_terminal_error
             terminal_error
             "Codex dynamic tool context injection produced extra_messages, which cannot be projected into an active app-server turn"
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       record_terminal_error
         terminal_error
         ("Codex dynamic tool context injection raised after execution: "
          ^ Printexc.to_string exn))
;;

let dynamic_tool_of_oas ~keeper_name ~turn_count ~context ~tools
    ~(hooks : Agent_sdk.Hooks.hooks) ~event_bus ~context_injector ~terminal_error
    (tool : Agent_sdk.Tool.t) =
  { Runtime_codex_app_server.name = tool.schema.name
  ; description = tool.schema.description
  ; input_schema = Agent_sdk.Types.params_to_input_schema tool.schema.parameters
  ; call =
      (fun ~call_id input ->
        let schedule : Agent_sdk.Tool_contract.schedule =
          { planned_index = 0
          ; batch_index = 0
          ; batch_size = 1
          ; execution_mode = Agent_sdk.Tool.execution_mode tool
          }
        in
        let invocation =
          Agent_sdk.Tool_contract.Invocation.create
            ~tool_use_id:call_id
            ~turn:turn_count
            ~schedule
            ~completion:(Agent_sdk.Tool.completion tool)
        in
        let pre_tool_use =
          invoke_turn_hook
            ~keeper_name
            ~turn_count
            ~hook_name:"pre_tool_use"
            hooks.pre_tool_use
            (Agent_sdk.Hooks.PreToolUse
               { invocation
               ; tool_name = tool.schema.name
               ; input
               ; accumulated_cost_usd = 0.0
               })
        in
        match pre_tool_use with
        | Block detail -> { Runtime_codex_app_server.success = false; content = detail }
        | HookFailed { stage; detail } ->
          let detail =
            Printf.sprintf
              "pre_tool_use hook failed at %s: %s"
              (Agent_sdk.Hooks.hook_stage_to_string stage)
              detail
          in
          { Runtime_codex_app_server.success = false; content = detail }
        | (ElicitToolApproval _ | ElicitInput _) as decision ->
          let detail =
            Printf.sprintf
              "Codex dynamic tool cannot settle hook decision %s without a host approval callback"
              (Agent_sdk.Hooks.decision_kind_to_string
                 (Agent_sdk.Hooks.classify_decision decision))
          in
          record_terminal_error terminal_error detail;
          { Runtime_codex_app_server.success = false; content = detail }
        | (AdjustParams _ | Nudge _) as decision ->
          let detail =
            Printf.sprintf
              "Codex dynamic tool received illegal pre_tool_use decision %s"
              (Agent_sdk.Hooks.decision_kind_to_string
                 (Agent_sdk.Hooks.classify_decision decision))
          in
          record_terminal_error terminal_error detail;
          { Runtime_codex_app_server.success = false; content = detail }
        | Continue ->
          (match
             Agent_sdk.Agent_tools.find_and_execute_tool
               ~context
               ~tools
               ~hooks
               ~event_bus
               ~tracer:Agent_sdk.Tracing.null
               ~agent_name:keeper_name
               ~invocation
               tool.schema.name
               input
           with
           | Ok result ->
             apply_context_injection
               ~terminal_error
               ~context
               ~context_injector
               ~tool_name:result.tool_name
               ~input:result.input
               ~content:result.content
               ~outcome:result.outcome;
             { Runtime_codex_app_server.success =
                 not (Agent_sdk.Types.tool_result_outcome_is_error result.outcome)
             ; content = result.content
             }
           | Error error ->
             let detail = tool_hook_error_to_string error in
             (match error with
              | Agent_sdk.Agent_tools.Hook_execution_failed
                  { stage = (Post_tool_use | Post_tool_use_failure); _ } ->
                record_terminal_error terminal_error detail;
                { Runtime_codex_app_server.success = true
                ; content = "Tool completed, but its post-execution hook failed; do not retry"
                }
              | Agent_sdk.Agent_tools.Hook_execution_failed _ ->
                { Runtime_codex_app_server.success = false; content = detail })))
  }
;;

let dynamic_tools ~keeper_name ~turn_count ~tools ~hooks ~event_bus ~context_injector
    ~context ~terminal_error =
  match tools, context with
  | [], _ -> Ok []
  | _ :: _, None ->
    Error
      (config_error
         ~field:"context"
         "Codex dynamic tools require the Keeper shared context")
  | tools, Some context ->
    Ok
      (List.map
         (dynamic_tool_of_oas
            ~keeper_name
            ~turn_count
            ~context
            ~tools
            ~hooks
            ~event_bus
            ~context_injector
            ~terminal_error)
         tools)
;;

let codex_error_to_sdk_error = function
  | Runtime_codex_app_server.Invalid_config detail ->
    config_error ~field:"codex_app_server" detail
  | Runtime_codex_app_server.Subscription_required detail ->
    config_error ~field:"codex_subscription" detail
  | error -> Agent_sdk.Error.Internal (Runtime_codex_app_server.error_to_string error)
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks
    ~system_prompt ~tools ~initial_messages ~model_input_projection ~hooks
    ~context_injector ~context ~event_bus ~enable_thinking
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
    let hooks = Option.value hooks ~default:Agent_sdk.Hooks.empty in
    let* stored_session =
      match Keeper_codex_session_store.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Codex session binding load failed: " ^ detail))
    in
    let* thread_mode, turn_count =
      match stored_session with
      | None -> Ok (Runtime_codex_app_server.Start, 1)
      | Some session when not (String.equal session.runtime_id runtime_id) ->
        Error
          (config_error
             ~field:"codex_session.runtime_id"
             (Printf.sprintf
                "stored runtime %S does not match selected runtime %S"
                session.runtime_id
                runtime_id))
      | Some { phase = Settled _; turn_count; _ } when turn_count = Int.max_int ->
        Error
          (config_error
             ~field:"codex_session.turn_count"
             "stored Codex session turn count cannot be incremented")
      | Some { phase = Settled { thread_id; _ }; turn_count; _ } ->
        Ok
          (Runtime_codex_app_server.Resume { thread_id }, turn_count + 1)
      | Some { phase = Start _; _ } ->
        Error
          (config_error
             ~field:"codex_session.phase"
             "stored Codex session has an incomplete thread start; refusing duplicate execution")
      | Some { phase = Active _; _ } ->
        Error
          (config_error
             ~field:"codex_session.phase"
             "stored Codex session has an active unsettled attempt; refusing duplicate execution")
      | Some { phase = Turn_inflight _; _ } ->
        Error
          (config_error
             ~field:"codex_session.phase"
             "stored Codex session has an in-flight turn; refusing duplicate execution")
    in
    let* prepared =
      prepare_turn
        ~keeper_name
        ~turn_count
        ~system_prompt
        ~tools
        ~initial_messages
        ~model_input_projection
        ~hooks:(Some hooks)
        ~enable_thinking
    in
    let tool_surface_sha256 =
      Keeper_codex_session_store.tool_surface_sha256 prepared.tools
    in
    let* () =
      match stored_session with
      | None -> Ok ()
      | Some session
        when String.equal session.tool_surface_sha256 tool_surface_sha256 ->
        Ok ()
      | Some session ->
        Error
          (config_error
             ~field:"codex_session.tool_surface_sha256"
             (Printf.sprintf
                "stored Codex thread tool surface %s does not match current surface %s"
                session.tool_surface_sha256
                tool_surface_sha256))
    in
    let* developer_messages, history = project_messages prepared.messages in
    let* prompt =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> text_of_blocks ~field:"goal_blocks" blocks
    in
    let developer_instructions =
      prepared.system_prompt :: developer_messages
      |> List.filter (fun text -> String.trim text <> "")
      |> String.concat "\n\n"
      |> String_util.trim_to_option
    in
    let client_config =
      { Runtime_codex_app_server.cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; developer_instructions
      ; timeout_s = config.timeout_s
      }
    in
    let terminal_error = ref None in
    let* dynamic_tools =
      dynamic_tools
        ~keeper_name
        ~turn_count
        ~tools:prepared.tools
        ~hooks
        ~event_bus
        ~context_injector
        ~context
        ~terminal_error
    in
    let* claimed_session =
      match
        Keeper_codex_session_store.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Codex session claim failed: " ^ detail))
    in
    let session_state = ref claimed_session in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail -> Error (Printf.sprintf "Codex session %s failed: %s" label detail)
    in
    let started_at = Time_compat.now () in
    (match
       Runtime_codex_app_server.run_turn
         ~mgr:(Eio.Stdenv.process_mgr env)
         ~clock
         ~dynamic_tools
         ?reasoning_effort:prepared.reasoning_effort
         ~thread_mode
         ~history
         ~on_thread_ready:(fun ~thread_id ->
           update_session "active transition" (fun expected ->
             Keeper_codex_session_store.mark_active
               ~base_path
               ~keeper_name
               ~expected
               ~thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_starting:(fun ~thread_id ->
           update_session "turn-starting transition" (fun expected ->
             Keeper_codex_session_store.mark_turn_starting
               ~base_path
               ~keeper_name
               ~expected
               ~thread_id
               ~updated_at:(Time_compat.now ())))
         ~on_turn_started:(fun ~thread_id ~turn_id ->
           update_session "turn-started transition" (fun expected ->
             Keeper_codex_session_store.mark_turn_started
               ~base_path
               ~keeper_name
               ~expected
               ~thread_id
               ~turn_id
               ~updated_at:(Time_compat.now ())))
         client_config
         ~prompt
     with
     | Error error -> Error (codex_error_to_sdk_error error)
     | Ok turn ->
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
       let* () =
         match !terminal_error with
         | None -> Ok ()
         | Some detail -> Error (internal_error detail)
       in
       let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
       let response =
         { Agent_sdk.Types.id = turn.turn_id
         ; model = turn.model
         ; stop_reason = EndTurn
         ; content = [ Text turn.text ]
         ; usage = None
         ; telemetry =
             Some
               { Agent_sdk.Types.default_inference_telemetry with
                 request_latency_ms = Some latency_ms
               ; canonical_model_id = Some turn.model
               }
         }
       in
       let after_turn =
         invoke_turn_hook
           ~keeper_name
           ~turn_count
           ~hook_name:"after_turn"
           hooks.after_turn
           (Agent_sdk.Hooks.AfterTurn { turn = turn_count; response })
       in
       let* () =
         match after_turn with
         | Continue -> Ok ()
         | HookFailed { stage; detail } ->
           Error (hook_error ~hook_name:"after_turn" ~stage detail)
         | decision -> Error (illegal_hook_decision ~hook_name:"after_turn" decision)
       in
       let on_stop =
         invoke_turn_hook
           ~keeper_name
           ~turn_count
           ~hook_name:"on_stop"
           hooks.on_stop
           (Agent_sdk.Hooks.OnStop { reason = response.stop_reason; response })
       in
       let* () =
         match on_stop with
         | Continue -> Ok ()
         | HookFailed { stage; detail } ->
           Error (hook_error ~hook_name:"on_stop" ~stage detail)
         | decision -> Error (illegal_hook_decision ~hook_name:"on_stop" decision)
       in
       let* () =
         match
           Keeper_codex_session_store.settle
             ~base_path
             ~keeper_name
             ~expected:!session_state
             ~thread_id:turn.thread_id
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
           ~oas_internal_runtime_allowed:false
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
;;
