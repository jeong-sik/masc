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
           "antigravity-cli Keeper projection currently admits text blocks only")
  in
  loop [] blocks
;;

let user_message text : Agent_sdk.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let hook_error ~hook_name ~stage detail =
  internal_error
    (Printf.sprintf
       "Antigravity runtime %s hook failed at %s: %s"
       hook_name
       (Agent_sdk.Hooks.hook_stage_to_string stage)
       detail)
;;

let illegal_hook_decision ~hook_name decision =
  config_error
    ~field:"hooks"
    (Printf.sprintf
       "Antigravity runtime %s hook returned unsupported decision %s"
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

let render_message (message : Agent_sdk.Types.message) =
  let* text = text_of_blocks ~field:"initial_messages" message.content in
  let role =
    match message.role with
    | System -> "SYSTEM"
    | User -> "USER"
    | Assistant -> "ASSISTANT"
    | Tool -> "TOOL"
  in
  if message.role = Tool
  then
    Error
      (config_error
         ~field:"initial_messages"
         "antigravity-cli history projection does not admit OAS tool messages")
  else Ok (Printf.sprintf "%s:\n%s" role text)
;;

let render_messages messages =
  let rec loop acc = function
    | [] -> Ok (String.concat "\n\n" (List.rev acc))
    | message :: rest ->
      let* rendered = render_message message in
      loop (rendered :: acc) rest
  in
  loop [] messages
;;

let prepare_prompt ~keeper_name ~turn_count ~is_resume ~goal ~system_prompt
    ~initial_messages ~model_input_projection ~hooks =
  let input_messages =
    if is_resume then [ user_message goal ] else initial_messages @ [ user_message goal ]
  in
  let before_turn =
    invoke_turn_hook
      ~keeper_name
      ~turn_count
      ~hook_name:"before_turn"
      hooks.Agent_sdk.Hooks.before_turn
      (Agent_sdk.Hooks.BeforeTurn { turn = turn_count; messages = input_messages })
  in
  let* messages =
    match before_turn with
    | Continue -> Ok input_messages
    | Nudge text -> Ok (input_messages @ [ user_message text ])
    | HookFailed { stage; detail } -> Error (hook_error ~hook_name:"before_turn" ~stage detail)
    | decision -> Error (illegal_hook_decision ~hook_name:"before_turn" decision)
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
         ; last_tool_results = []
         ; current_params = Agent_sdk.Hooks.default_turn_params
         ; reasoning = Agent_sdk.Hooks.empty_reasoning_summary
         })
  in
  let* params =
    match before_turn_params with
    | Continue -> Ok Agent_sdk.Hooks.default_turn_params
    | AdjustParams params -> Ok params
    | HookFailed { stage; detail } ->
      Error (hook_error ~hook_name:"before_turn_params" ~stage detail)
    | decision -> Error (illegal_hook_decision ~hook_name:"before_turn_params" decision)
  in
  let unsupported field value =
    match value with
    | None -> Ok ()
    | Some _ ->
      Error
        (config_error
           ~field
           "antigravity-cli does not project this OAS turn parameter; select an exact Antigravity model id")
  in
  let* () = unsupported "temperature" params.temperature in
  let* () = unsupported "thinking_budget" params.thinking_budget in
  let* () = unsupported "reasoning_effort" params.reasoning_effort in
  let* () = unsupported "enable_thinking" params.enable_thinking in
  let* () = unsupported "preserve_thinking" params.preserve_thinking in
  let* () = unsupported "tool_choice" params.tool_choice in
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
              ("Antigravity runtime model input projection raised: "
               ^ Printexc.to_string exn)))
  in
  let* rendered = render_messages messages in
  let system_prompt =
    Option.value params.system_prompt_override ~default:system_prompt
  in
  let system_context =
    [ (if is_resume then None else String_util.trim_to_option system_prompt)
    ; Option.bind params.extra_system_context String_util.trim_to_option
    ]
    |> List.filter_map Fun.id
  in
  Ok (String.concat "\n\n" (system_context @ [ rendered ]))
;;

let antigravity_error_to_sdk_error = function
  | Runtime_antigravity_cli.Invalid_config detail ->
    config_error ~field:"antigravity_cli" detail
  | error -> Agent_sdk.Error.Internal (Runtime_antigravity_cli.error_to_string error)
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks ~system_prompt
    ~initial_messages ~model_input_projection ~hooks
    ~(config : Runtime_execution.antigravity_cli) =
  let hooks = Option.value hooks ~default:Agent_sdk.Hooks.empty in
  let* goal =
    match goal_blocks with
    | None -> Ok goal
    | Some blocks -> text_of_blocks ~field:"goal_blocks" blocks
  in
  let* stored_session =
    match Keeper_antigravity_session_store.load ~base_path ~keeper_name with
    | Ok session -> Ok session
    | Error detail ->
      Error (internal_error ("Antigravity session binding load failed: " ^ detail))
  in
  let* session_mode, turn_count =
    match stored_session with
    | None -> Ok (Runtime_antigravity_cli.Start, 1)
    | Some session when not (String.equal session.runtime_id runtime_id) ->
      Error
        (config_error
           ~field:"antigravity_session.runtime_id"
           (Printf.sprintf
              "stored runtime %S does not match selected runtime %S"
              session.runtime_id
              runtime_id))
    | Some { phase = Settled { conversation_id }; turn_count; _ }
      when turn_count < Int.max_int ->
      Ok (Runtime_antigravity_cli.Resume { conversation_id }, turn_count + 1)
    | Some { phase = Settled _; _ } ->
      Error
        (config_error
           ~field:"antigravity_session.turn_count"
           "stored Antigravity session turn count cannot be incremented")
    | Some { phase = Claimed _; _ } ->
      Error
        (config_error
           ~field:"antigravity_session.phase"
           "stored Antigravity session has an unsettled claim; refusing duplicate execution")
  in
  let is_resume =
    match session_mode with
    | Runtime_antigravity_cli.Start -> false
    | Runtime_antigravity_cli.Resume _ -> true
  in
  let* prompt =
    prepare_prompt
      ~keeper_name
      ~turn_count
      ~is_resume
      ~goal
      ~system_prompt
      ~initial_messages
      ~model_input_projection
      ~hooks
  in
  let client_config : Runtime_antigravity_cli.config =
    { cli_path = config.cli_path
    ; cwd = base_path
    ; model = config.model
    ; timeout_s = config.timeout_s
    }
  in
  let* () =
    match Runtime_antigravity_cli.validate_run ~session_mode client_config ~prompt with
    | Ok () -> Ok ()
    | Error error -> Error (antigravity_error_to_sdk_error error)
  in
  let* claimed =
    match
      Keeper_antigravity_session_store.claim
        ~base_path
        ~keeper_name
        ~expected:stored_session
        ~runtime_id
        ~updated_at:(Time_compat.now ())
    with
    | Ok session -> Ok session
    | Error detail -> Error (internal_error ("Antigravity session claim failed: " ^ detail))
  in
  let started_at = Time_compat.now () in
  match Runtime_antigravity_cli.run_turn ~session_mode client_config ~prompt with
  | Error error -> Error (antigravity_error_to_sdk_error error)
  | Ok turn ->
    let* () =
      if turn.num_turns = turn_count
      then Ok ()
      else
        Error
          (internal_error
             (Printf.sprintf
                "Antigravity CLI reported turn count %d but durable session expected %d"
                turn.num_turns
                turn_count))
    in
    let latency_ms = Int.of_float ((Time_compat.now () -. started_at) *. 1000.0) in
    let usage : Agent_sdk.Types.api_usage =
      { input_tokens = turn.usage.input_tokens
      ; output_tokens = turn.usage.output_tokens
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = turn.usage.cache_read_tokens
      ; cost_usd = None
      }
    in
    let response =
      { Agent_sdk.Types.id =
          Printf.sprintf "%s:%d" turn.conversation_id turn.num_turns
      ; model = turn.model
      ; stop_reason = EndTurn
      ; content = [ Text turn.text ]
      ; usage = Some usage
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
    let* _settled =
      match
        Keeper_antigravity_session_store.settle
          ~base_path
          ~keeper_name
          ~expected:claimed
          ~conversation_id:turn.conversation_id
          ~usage:turn.usage
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Antigravity session settlement failed: " ^ detail))
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
          [ "antigravity_cli"
          ; "execution_mode=plan_sandbox"
          ; "tool_owner=official_client"
          ; "masc_tool_hooks=unavailable"
          ; Printf.sprintf "permission_mode=%s" turn.permission_mode
          ; Printf.sprintf "tool_calls=%d" turn.tool_calls
          ; Printf.sprintf "resumed=%b" turn.resumed
          ; Printf.sprintf "turn_count=%d" turn_count
          ; Printf.sprintf "input_tokens=%d" turn.usage.input_tokens
          ; Printf.sprintf "output_tokens=%d" turn.usage.output_tokens
          ; Printf.sprintf "thinking_tokens=%d" turn.usage.thinking_tokens
          ; Printf.sprintf "cache_read_tokens=%d" turn.usage.cache_read_tokens
          ; Printf.sprintf "total_tokens=%d" turn.usage.total_tokens
          ]
        ~candidate_count:1
        ~selected_model_raw:(Some turn.model)
        ~capture
        ~attempt_details_source:"antigravity_cli"
        ~oas_internal_runtime_allowed:false
        ()
    in
    Ok
      { Runtime_agent.response
      ; checkpoint = None
      ; session_id = turn.conversation_id
      ; turns = turn_count
      ; trace_ref = None
      ; run_validation = None
      ; runtime_observation = Some runtime_observation
      ; stop_reason = Completed
      }
;;
