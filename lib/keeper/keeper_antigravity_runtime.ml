open Result.Syntax

module Host = Keeper_official_client_host
module Session = Keeper_official_client_session_store

let runtime_label = "Antigravity"

let config_error ~field detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })
;;

let internal_error detail = Agent_sdk.Error.Internal detail

let runtime_error_to_sdk_error = function
  | Runtime_antigravity.Invalid_config detail ->
    config_error ~field:"antigravity_cli" detail
  | error -> Agent_sdk.Error.Internal (Runtime_antigravity.error_to_string error)
;;

let recovery_failure_of_runtime_error = function
  | Runtime_antigravity.Spawn_failed _ -> Session.Transient_spawn_failed
  | Runtime_antigravity.Process_exited _ | Runtime_antigravity.Timeout _ ->
    Session.Transport_interrupted
  | Runtime_antigravity.Invalid_config _
  | Runtime_antigravity.Protocol_error _ ->
    Session.Protocol_failed
  | Runtime_antigravity.State_callback_failed _ -> Session.State_persistence_failed
  | Runtime_antigravity.Turn_failed _ -> Session.Provider_rejected
;;

let user_message text : Agent_sdk.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let render_message (message : Agent_sdk.Types.message) =
  let* text =
    Host.text_of_blocks
      ~runtime_label
      ~field:"initial_messages"
      message.content
  in
  match message.role with
  | Tool ->
    Error
      (config_error
         ~field:"initial_messages"
         "antigravity-cli history projection does not admit OAS tool messages")
  | System -> Ok ("SYSTEM:\n" ^ text)
  | User -> Ok ("USER:\n" ^ text)
  | Assistant -> Ok ("ASSISTANT:\n" ^ text)
;;

let render_messages messages =
  let rec loop rendered = function
    | [] -> Ok (String.concat "\n\n" (List.rev rendered))
    | message :: rest ->
      let* text = render_message message in
      loop (text :: rendered) rest
  in
  loop [] messages
;;

let reject_unprojected_tool_contracts ~tools ~hooks ~context_injector =
  if tools <> []
  then
    Error
      (config_error
         ~field:"tools"
         "agy --print does not expose a custom-tool transport; MASC tools cannot be projected into the Antigravity built-in tool loop")
  else if Option.is_some context_injector
  then
    Error
      (config_error
         ~field:"context_injector"
         "Antigravity built-in tool results are not available to the MASC context injector")
  else
    match hooks with
    | Some
        { Agent_sdk.Hooks.pre_tool_use = Some _
        ; _
        }
    | Some { post_tool_use = Some _; _ }
    | Some { post_tool_use_failure = Some _; _ }
    | Some { on_tool_error = Some _; _ } ->
      Error
        (config_error
           ~field:"hooks"
           "Antigravity built-in tool calls cannot run MASC tool lifecycle hooks")
    | None | Some _ -> Ok ()
;;

let prepare_prompt ~keeper_name ~turn_count ~is_resume ~goal ~system_prompt
    ~initial_messages ~model_input_projection ~hooks =
  let messages =
    (if is_resume then [] else initial_messages) @ [ user_message goal ]
  in
  let* prepared =
    Host.prepare_turn
      ~runtime_label
      ~keeper_name
      ~turn_count
      ~system_prompt
      ~tools:[]
      ~initial_messages:messages
      ~model_input_projection
      ~hooks
      ~enable_thinking:None
  in
  let* () =
    match prepared.reasoning_effort with
    | None -> Ok ()
    | Some _ ->
      Error
        (config_error
           ~field:"reasoning_effort"
           "Antigravity effort is owned by runtime.toml and cannot be replaced by an OAS turn hook")
  in
  let* rendered = render_messages prepared.messages in
  let sections =
    [ Option.map (fun text -> "SYSTEM INSTRUCTIONS:\n" ^ text)
        (String_util.trim_to_option prepared.system_prompt)
    ; String_util.trim_to_option rendered
    ]
    |> List.filter_map Fun.id
  in
  Ok (String.concat "\n\n" sections)
;;

let effort_label = function
  | None -> "default"
  | Some Runtime_antigravity.Low -> "low"
  | Some Runtime_antigravity.Medium -> "medium"
  | Some Runtime_antigravity.High -> "high"
;;

let execution_mode_label = function
  | Runtime_antigravity.Plan -> "plan"
  | Runtime_antigravity.Accept_edits -> "accept-edits"
;;

let runtime_binding_id runtime_id (config : Runtime_execution.antigravity_cli) =
  let canonical =
    `Assoc
      [ "agent", Option.fold ~none:`Null ~some:(fun value -> `String value) config.agent
      ; "disable_slash_commands", `Bool config.disable_slash_commands
      ; "effort", `String (effort_label config.effort)
      ; "execution_mode", `String (execution_mode_label config.execution_mode)
      ; "model", `String config.model
      ; "sandbox", `Bool config.sandbox
      ]
    |> Yojson.Safe.to_string
  in
  let digest = Digestif.SHA256.(digest_string canonical |> to_hex) in
  runtime_id ^ "#" ^ digest
;;

let provider_turn_identity ~conversation_id ~num_turns =
  Printf.sprintf "%s:ordinal:%d" conversation_id num_turns
;;

let run ~runtime_id ~keeper_name ~base_path ~goal ~goal_blocks ~system_prompt
    ~tools ~initial_messages ~model_input_projection ~hooks ~context_injector
    ~enable_thinking ~(config : Runtime_execution.antigravity_cli) =
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | None, _ ->
    Error
      (config_error
         ~field:"eio_env"
         "Antigravity CLI runtime requires the initialized Eio standard environment")
  | _, None ->
    Error
      (config_error
         ~field:"eio_clock"
         "Antigravity CLI runtime requires the initialized Eio clock")
  | Some env, Some clock ->
    let* () = reject_unprojected_tool_contracts ~tools ~hooks ~context_injector in
    let* () =
      match enable_thinking with
      | None | Some true -> Ok ()
      | Some false ->
        Error
          (config_error
             ~field:"enable_thinking"
             "agy has no no-thinking flag; configure Antigravity effort in runtime.toml instead")
    in
    let hooks = Option.value hooks ~default:Agent_sdk.Hooks.empty in
    let owner_epoch = Session.process_epoch () in
    let binding_runtime_id = runtime_binding_id runtime_id config in
    let* stored_session =
      match Session.load ~base_path ~keeper_name with
      | Ok session -> Ok session
      | Error detail ->
        Error (internal_error ("Antigravity session binding load failed: " ^ detail))
    in
    let* stored_session =
      match stored_session with
      | Some ({ Session.phase = (Start _ | Active _ | Turn_inflight _); _ } as expected) ->
        (match
           Session.reconcile_process_restart
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
        Session.plan_claim
          ~expected:stored_session
          ~client_kind:Antigravity
          ~runtime_id:binding_runtime_id
      with
      | Ok plan -> Ok plan
      | Error detail ->
        Error (config_error ~field:"official_client_session.claim" detail)
    in
    let conversation_mode =
      match claim_plan.previous_settlement with
      | None -> Runtime_antigravity.Start
      | Some { session_id; _ } -> Runtime_antigravity.Resume { conversation_id = session_id }
    in
    let is_resume = Option.is_some claim_plan.previous_settlement in
    let turn_count = claim_plan.turn_count in
    let* goal =
      match goal_blocks with
      | None -> Ok goal
      | Some blocks -> Host.text_of_blocks ~runtime_label ~field:"goal_blocks" blocks
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
        ~hooks:(Some hooks)
    in
    let tool_surface_sha256 = Session.tool_surface_sha256 [] in
    let* () =
      match claim_plan.required_tool_surface_sha256 with
      | None -> Ok ()
      | Some stored when String.equal stored tool_surface_sha256 -> Ok ()
      | Some _ ->
        Error
          (config_error
             ~field:"official_client_session.tool_surface_sha256"
             "stored Antigravity session has a different projected MASC tool surface")
    in
    let client_config : Runtime_antigravity.config =
      { cli_path = config.cli_path
      ; cwd = base_path
      ; model = config.model
      ; agent = config.agent
      ; effort = config.effort
      ; execution_mode = config.execution_mode
      ; sandbox = config.sandbox
      ; disable_slash_commands = config.disable_slash_commands
      ; timeout_s = config.timeout_s
      }
    in
    let* () =
      match
        Runtime_antigravity.validate_turn
          ~conversation_mode
          client_config
          ~prompt
      with
      | Ok () -> Ok ()
      | Error error -> Error (runtime_error_to_sdk_error error)
    in
    let* claimed =
      match
        Session.claim
          ~base_path
          ~keeper_name
          ~expected:stored_session
          ~client_kind:Antigravity
          ~owner_epoch
          ~runtime_id:binding_runtime_id
          ~tool_surface_sha256
          ~updated_at:(Time_compat.now ())
      with
      | Ok session -> Ok session
      | Error detail -> Error (internal_error ("Antigravity session claim failed: " ^ detail))
    in
    let session_state = ref claimed in
    let recovery_failure = ref Session.Transport_interrupted in
    let update_session label transition =
      match transition !session_state with
      | Ok next ->
        session_state := next;
        Ok ()
      | Error detail ->
        recovery_failure := Session.State_persistence_failed;
        Error (Printf.sprintf "Antigravity session %s failed: %s" label detail)
    in
    let require_recovery detail =
      match !session_state with
      | { Session.phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
      | expected ->
        (match
           Session.require_recovery
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
         | Error recovery_detail -> Error recovery_detail)
    in
    let settle_failed_claim detail =
      match Session.failure_disposition !recovery_failure with
      | Transient ->
        (match !session_state with
         | { phase = (Ready | Settled _ | Recovery_required _); _ } -> Ok ()
         | expected ->
           (match
              Session.release_transient
                ~base_path
                ~keeper_name
                ~expected
                ~failure:!recovery_failure
                ~released_at:(Time_compat.now ())
            with
            | Ok released ->
              session_state := released;
              Ok ()
            | Error recovery_detail -> Error recovery_detail))
      | Ambiguous | Fatal -> require_recovery detail
    in
    let started_at = Time_compat.now () in
    let turn_result =
      try
        (match
           Runtime_antigravity.run_turn
             ~conversation_mode
             ~mgr:(Eio.Stdenv.process_mgr env)
             ~clock
             ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
             ~on_conversation_ready:(fun ~conversation_id ->
               let* () =
                 update_session "active transition" (fun expected ->
                   Session.mark_active
                     ~base_path
                     ~keeper_name
                     ~expected
                     ~session_id:conversation_id
                     ~updated_at:(Time_compat.now ()))
               in
               update_session "turn-starting transition" (fun expected ->
                 Session.mark_turn_starting
                   ~base_path
                   ~keeper_name
                   ~expected
                   ~session_id:conversation_id
                   ~updated_at:(Time_compat.now ())))
             client_config
             ~prompt
         with
         | Error error ->
           recovery_failure := recovery_failure_of_runtime_error error;
           Error (runtime_error_to_sdk_error error)
         | Ok turn ->
           recovery_failure := Session.Protocol_failed;
           let* () =
             if Bool.equal is_resume turn.resumed
             then Ok ()
             else
               Error
                 (internal_error
                    "Antigravity reported a conversation mode different from the durable claim")
           in
           let* () =
             if turn.num_turns = turn_count
             then Ok ()
             else
               Error
                 (internal_error
                    (Printf.sprintf
                       "Antigravity reported conversation ordinal %d but durable session expected %d"
                       turn.num_turns
                       turn_count))
           in
           let turn_id =
             provider_turn_identity
               ~conversation_id:turn.conversation_id
               ~num_turns:turn.num_turns
           in
           recovery_failure := Session.State_persistence_failed;
           let* () =
             update_session "turn identity transition" (fun expected ->
               Session.mark_turn_started
                 ~base_path
                 ~keeper_name
                 ~expected
                 ~session_id:turn.conversation_id
                 ~turn_id
                 ~updated_at:(Time_compat.now ()))
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
             { Agent_sdk.Types.id = turn_id
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
           recovery_failure := Session.Host_hook_failed;
           let* () =
             match
               Host.invoke_turn_hook
                 ~keeper_name
                 ~turn_count
                 ~hook_name:"after_turn"
                 hooks.after_turn
                 (Agent_sdk.Hooks.AfterTurn { turn = turn_count; response })
             with
             | Continue -> Ok ()
             | HookFailed { stage; detail } ->
               Error (Host.hook_error ~runtime_label ~hook_name:"after_turn" ~stage detail)
             | decision ->
               Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"after_turn" decision)
           in
           let* () =
             match
               Host.invoke_turn_hook
                 ~keeper_name
                 ~turn_count
                 ~hook_name:"on_stop"
                 hooks.on_stop
                 (Agent_sdk.Hooks.OnStop { reason = response.stop_reason; response })
             with
             | Continue -> Ok ()
             | HookFailed { stage; detail } ->
               Error (Host.hook_error ~runtime_label ~hook_name:"on_stop" ~stage detail)
             | decision ->
               Error (Host.illegal_hook_decision ~runtime_label ~hook_name:"on_stop" decision)
           in
           recovery_failure := Session.State_persistence_failed;
           let* () =
             match
               Session.settle
                 ~base_path
                 ~keeper_name
                 ~expected:!session_state
                 ~session_id:turn.conversation_id
                 ~turn_id
                 ~updated_at:(Time_compat.now ())
             with
             | Ok settled ->
               session_state := settled;
               Ok ()
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
                 ; "tool_owner=official_client"
                 ; "masc_tool_surface=not_projected"
                 ; "provider_turn_identity=conversation_ordinal"
                 ; Printf.sprintf "execution_mode=%s" (execution_mode_label config.execution_mode)
                 ; Printf.sprintf "sandbox=%b" config.sandbox
                 ; Printf.sprintf "permission_mode=%s" turn.permission_mode
                 ; Printf.sprintf "tool_steps=%d" turn.tool_steps
                 ; Printf.sprintf "tool_errors=%d" turn.tool_errors
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
             })
      with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        recovery_failure := Session.Transport_interrupted;
        let detail = "Antigravity turn cancelled: " ^ Printexc.to_string exn in
        (match Eio.Cancel.protect (fun () -> settle_failed_claim detail) with
         | Ok () -> ()
         | Error recovery_detail ->
           Log.Keeper.error
             ~keeper_name
             "Antigravity cancellation recovery persistence failed: %s"
             recovery_detail);
        Printexc.raise_with_backtrace exn backtrace
    in
    (match turn_result with
     | Ok _ -> turn_result
     | Error original_error ->
       let original_detail = Agent_sdk.Error.to_string original_error in
       (match Eio.Cancel.protect (fun () -> settle_failed_claim original_detail) with
        | Ok () -> turn_result
        | Error recovery_detail ->
          Error
            (internal_error
               (Printf.sprintf
                  "Antigravity turn failed and recovery state persistence also failed: original=%s recovery=%s"
                  original_detail
                  recovery_detail))))
;;
